import Foundation
import AVFoundation
import Speech
import os

/// Receives streaming recognition updates on the main actor. Confirmed text is appended by the
/// coordinator to its own accumulator (ORA-SM-002); volatile text feeds only the indicator preview
/// (ORA-ASR-004). Exactly one long-lived task calls these, in order (ORA-CC-003).
@MainActor
public protocol SpeechResultSink: AnyObject {
    /// A newly *finalized* segment — append verbatim to confirmed text.
    func speechDidConfirm(_ text: String)
    /// The current *volatile* tail — replaces the preview; never written to the target field.
    func speechDidReviseVolatile(_ text: String)
}

/// A single-resume race: `settle` from whichever of two tasks finishes first resumes the awaiter
/// exactly once; the loser is ignored. Lets `finalize` time out even when `analyzer.finalize` wedges
/// (an uncancellable hang that `withTaskGroup` would otherwise block on forever).
private final class FinalizeRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?
    func attach(_ c: CheckedContinuation<Bool, Never>) {
        lock.lock(); defer { lock.unlock() }
        if let r = result { c.resume(returning: r) } else { continuation = c }
    }
    func settle(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        result = value
        if let c = continuation { continuation = nil; c.resume(returning: value) }
    }

    /// Run `work` racing `timeout`, resuming on whichever finishes first WITHOUT awaiting the other (a
    /// wedged `work` can't block the caller). Returns `work`'s result, or `false` if the timeout wins.
    static func run(timeout: Duration, work: @escaping @Sendable () async -> Bool) async -> Bool {
        let race = FinalizeRace()
        let workTask = Task { race.settle(await work()) }
        let timer = Task { try? await Task.sleep(for: timeout); race.settle(false) }
        let result = await withCheckedContinuation { race.attach($0) }
        workTask.cancel(); timer.cancel()
        return result
    }
}

/// The shape both transcriber kinds' results share: `text` plus the `isFinal` that `SpeechModuleResult`
/// provides. Lets one generic results task serve `SpeechTranscriber` and `DictationTranscriber`, whose
/// `results` sequences are distinct opaque types.
private protocol TranscriptResult: SpeechModuleResult {
    var text: AttributedString { get }
}
extension SpeechTranscriber.Result: TranscriptResult {}
extension DictationTranscriber.Result: TranscriptResult {}

/// On-device streaming recognition (§8.4). Wraps the macOS-26 `SpeechAnalyzer` + `SpeechTranscriber`.
///
/// The **model asset** is kept resident for the app lifetime (ORA-ASR-005) so no dictation pays a
/// load, but each dictation runs on its **own** analyzer + transcriber + input stream + results task
/// (`beginSession`/`endSession`). Reusing a single analyzer across dictations corrupts it — by the
/// third `finalize(through:)` it hangs, and earlier sessions' text bleeds or drops into later ones.
/// Per-session isolation gives clean boundaries; the resident model keeps setup cheap.
///
/// `@MainActor`-isolated: every method is `await`-driven against the analyzer actor and does only
/// trivial synchronous work, so it never blocks main. The single results task (ORA-CC-003) then
/// forwards to the coordinator with zero actor hops (both are on the main actor).
@MainActor
public final class SpeechEngine {
    public enum EngineError: Error, Sendable {
        case modelUnavailable(ModelStatus)
    }

    /// Identifies ONE dictation's input stream. The audio bridge carries the token it was created with
    /// and `feed` drops buffers that don't match the live session, so a bridge still draining after a
    /// cancel can't bleed the previous dictation's trailing audio into the next transcript.
    public struct SessionToken: Sendable, Equatable {
        fileprivate let id: UInt64
    }

    private var locale: Locale
    private var modelReady = false            // model asset resident + inputFormat known (warm)
    private var analyzer: SpeechAnalyzer?

    /// A fully **prepared** (but not started) analyzer session kept ready so `beginSession` only has
    /// to `start(inputSequence:)` — moving the slow `prepareToAnalyze` OFF the hotkey path. Prepared
    /// at warm-up and re-prepared in the background after each dictation ends.
    private struct PreparedSession {
        let transcriber: Transcriber
        let analyzer: SpeechAnalyzer
        let stream: AsyncStream<AnalyzerInput>
        let continuation: AsyncStream<AnalyzerInput>.Continuation
    }
    private var spare: PreparedSession?
    private var preparingSpare = false

    /// The live session's input continuation + its token, behind a lock.
    ///
    /// This is written on the MainActor (`beginSession`/`endSession`/`teardownActive`) and read from
    /// the detached audio bridge on every buffer, so it CANNOT be a bare `nonisolated(unsafe) var`:
    /// the continuation wraps a class reference, and an unsynchronized reader can retain a pointer the
    /// writer just released. The discard teardown path (cancel/abort) does not await the bridge, so
    /// that overlap is reachable in practice. One uncontended lock per buffer, and none of it is on the
    /// hotkey→capture-start hot path.
    private struct ActiveInput: Sendable {
        let token: SessionToken
        let continuation: AsyncStream<AnalyzerInput>.Continuation
    }
    private let activeInput = OSAllocatedUnfairLock<ActiveInput?>(initialState: nil)
    private var nextSessionID: UInt64 = 0
    private var resultsTask: Task<Void, Never>?

    /// The analyzer's chosen input format; AudioCapture converts to this.
    public private(set) var inputFormat: AVAudioFormat?

    /// Set by the coordinator before a session; results are delivered here in order.
    public weak var sink: SpeechResultSink?

    /// Which transcriber kind the *next prepared spare* should use. Seeded from whether the user has a
    /// custom vocabulary and re-set by every `beginSession`, so the pre-prepared spare is normally
    /// already the right kind and the hotkey path never pays to build one inline.
    private var biasingWanted: Bool

    public init(locale: Locale, biasing: Bool = false) {
        self.locale = locale
        self.biasingWanted = biasing
    }

    // MARK: Model asset lifecycle (ORA-ASR-006 / E3–E4)

    /// The two transcriber kinds a session can run on. `SpeechTranscriber` is the default streaming
    /// path; `DictationTranscriber` is the ONLY one that honours `AnalysisContext.contextualStrings`,
    /// so custom-vocabulary biasing (ORA-VOC-001/002, M7) requires it. Both vend `SpeechModuleResult`s
    /// carrying `text` + `isFinal`, so everything downstream is shared.
    fileprivate enum Transcriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let t): return t
            case .dictation(let t): return t
            }
        }
        /// True for the kind that actually applies contextual strings.
        var supportsBiasing: Bool { if case .dictation = self { return true }; return false }
    }

    private func makeSpeechTranscriber() -> SpeechTranscriber {
        // Streaming preset with volatile results for the live preview (ORA-IND-010) and native
        // punctuation preserved (ORA-ASR-007). No etiquette/disfluency stripping (ORA-VOC-004).
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [])
    }

    private func makeDictationTranscriber() -> DictationTranscriber {
        // Same streaming shape as above, on the biasing-capable module.
        DictationTranscriber(locale: locale,
                             contentHints: [],
                             transcriptionOptions: [],
                             reportingOptions: [.volatileResults],
                             attributeOptions: [])
    }

    private func makeTranscriber(biasing: Bool) -> Transcriber {
        biasing ? .dictation(makeDictationTranscriber()) : .speech(makeSpeechTranscriber())
    }

    /// All BCP-47 locale ids the transcriber supports on this device (read dynamically — the Settings
    /// language list is never hard-coded).
    public func supportedLocaleIDs() async -> [String] {
        (await SpeechTranscriber.supportedLocales).map { $0.identifier(.bcp47) }
    }

    /// BCP-47 locale ids whose model is already installed on-device.
    public func installedLocaleIDs() async -> [String] {
        (await SpeechTranscriber.installedLocales).map { $0.identifier(.bcp47) }
    }

    public func modelStatus() async -> ModelStatus {
        guard let normalized = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        // If the locale's model is already installed system-wide, it's ready — no download needed.
        // `AssetInventory.status(forModules:)` can report `.supported` even when `installedLocales`
        // lists the locale, so trust `installedLocales` first (this is what macOS actually has).
        if await installedLocaleIDs().contains(normalized.identifier(.bcp47)) {
            return .installed
        }
        let t = makeSpeechTranscriber()
        switch await AssetInventory.status(forModules: [t]) {
        case .installed: return .installed
        case .downloading: return .downloading(fractionCompleted: 0)
        case .supported: return .missing
        case .unsupported: return .unsupported
        @unknown default: return .missing
        }
    }

    /// Download + install the model, reporting progress (ORA-ASR-006). Retryable; a throw is an
    /// onboarding state, never fatal (E4).
    public func installModel(onProgress: @escaping @Sendable (Double) -> Void) async throws {
        // Install the assets for BOTH transcriber kinds: a vocabulary user's sessions run on
        // `DictationTranscriber`, and its asset is not implied by `SpeechTranscriber`'s.
        let modules: [any SpeechModule] = [makeSpeechTranscriber(), makeDictationTranscriber()]
        // Reserve the locale so the asset stays resident once installed (R2).
        _ = try? await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
            return // nothing to install ⇒ already present
        }
        let observer = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            onProgress(p.fractionCompleted)
        }
        defer { observer.invalidate() }
        try await request.downloadAndInstall()
    }

    // MARK: Warmth (ORA-ASR-005 / ORA-LIF-001)

    /// Keep the model **asset** resident and determine the analyzer's input format. Does NOT start a
    /// persistent analyzer (see class note: reusing one corrupts it, per `CrossSessionTests`). Model
    /// retention keeps per-session setup fast (ORA-ASR-005). Idempotent.
    public func warmUp() async throws {
        guard !modelReady else { return }
        let status = await modelStatus()
        guard status == .installed else { throw EngineError.modelUnavailable(status) }

        // Reserve the locale so the weights stay in RAM independent of any analyzer's lifetime.
        _ = try? await AssetInventory.reserve(locale: locale)

        // A format both transcriber kinds accept, so switching to the biasing-capable one mid-life
        // never invalidates the format capture is already converting to. Falls back to the default
        // path's own format if no shared one exists (the biasing session then can't prepare, and
        // `makePreparedSession` degrades to `SpeechTranscriber`).
        let modules: [any SpeechModule] = [makeSpeechTranscriber(), makeDictationTranscriber()]
        if let shared = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) {
            self.inputFormat = shared
        } else {
            self.inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [makeSpeechTranscriber()])
        }
        modelReady = true
        spare = await makePreparedSession(biasing: biasingWanted)   // ready so the FIRST dictation starts instantly
    }

    public var isWarm: Bool { modelReady && inputFormat != nil }

    /// Whether the biasing-capable module's asset is present. `modelStatus()` deliberately answers for
    /// `SpeechTranscriber` only — it gates *recording*, which must never be blocked by a vocabulary
    /// feature — so this is the separate question "can custom vocabulary actually work right now?".
    public func biasingAssetInstalled() async -> Bool {
        await AssetInventory.status(forModules: [makeDictationTranscriber()]) == .installed
    }

    /// Fetch the biasing module's asset if the user has a vocabulary and it isn't installed.
    ///
    /// Without this the feature is dead on every EXISTING install: `installModel` covers both modules
    /// but only runs when `modelStatus()` reports the *SpeechTranscriber* asset missing — which it
    /// never is for someone already dictating. `makePreparedSession(biasing:)` would then fail to
    /// prepare and silently fall back to unbiased recognition, forever, with only a log line.
    /// Returns true when biasing is usable afterwards.
    @discardableResult
    public func ensureBiasingAsset() async -> Bool {
        guard modelReady else { return false }
        if await biasingAssetInstalled() { return true }
        Log.speech.notice("Custom vocabulary set but the dictation asset is missing — installing")
        do { try await installModel { _ in } }
        catch {
            Log.speech.error("Dictation asset install failed: \(error.localizedDescription)")
            return false
        }
        let ok = await biasingAssetInstalled()
        if ok { spare = nil; ensureSpare() }   // rebuild the spare now that the right kind can prepare
        return ok
    }

    // MARK: Per-session lifecycle (a fresh analyzer per dictation — clean boundaries)

    /// Build a fresh, fully-prepared session (the expensive `prepareToAnalyze` happens here, off the
    /// hotkey path). Returns nil if the model isn't ready.
    private func makePreparedSession(biasing: Bool) async -> PreparedSession? {
        guard let format = inputFormat else { return nil }
        if let session = await prepare(makeTranscriber(biasing: biasing), format: format) { return session }
        // A biasing session that can't be prepared (its asset absent on this host, or no shared audio
        // format) must NOT cost the user their dictation — fall back to the default transcriber and
        // lose only the vocabulary bias.
        guard biasing else { return nil }
        Log.speech.error("Biasing transcriber unavailable — falling back to SpeechTranscriber (vocabulary bias lost)")
        return await prepare(.speech(makeSpeechTranscriber()), format: format)
    }

    private func prepare(_ transcriber: Transcriber, format: AVAudioFormat) async -> PreparedSession? {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber.module],
            options: SpeechAnalyzer.Options(priority: .high, modelRetention: .processLifetime))
        do { try await analyzer.prepareToAnalyze(in: format) }
        catch { Log.speech.error("prepare spare failed: \(error.localizedDescription)"); return nil }
        return PreparedSession(transcriber: transcriber, analyzer: analyzer, stream: stream, continuation: cont)
    }

    /// Prepare the next spare in the background (during idle between dictations) so the next start is
    /// instant. No-op if one is already ready or being prepared.
    private func ensureSpare() {
        guard spare == nil, !preparingSpare, modelReady else { return }
        preparingSpare = true
        Task { [weak self] in
            guard let self else { return }
            let session = await self.makePreparedSession(biasing: self.biasingWanted)
            self.spare = session
            self.preparingSpare = false
        }
    }

    /// Start a dictation on a pre-prepared spare (instant): just apply vocabulary + `start`. Each
    /// dictation gets its OWN analyzer/transcriber/stream/results task, so no state can leak or drop
    /// across sessions (verified by `CrossSessionTests`).
    /// Returns the token identifying the started session, or **nil** if the session could not be
    /// started (model not ready, no preparable analyzer, `start` threw). A nil return MUST be treated
    /// as a failed start: without it the caller would show a live indicator over a session that has no
    /// transcriber attached and silently discard every buffer (ORA-REL-001).
    @discardableResult
    public func beginSession(vocabulary: [String]) async -> SessionToken? {
        guard modelReady else {
            Log.speech.error("beginSession: model not ready")
            return nil
        }
        teardownActive()   // defensive: never run two sessions on one analyzer

        // Contextual biasing only takes effect on `DictationTranscriber`, so the vocabulary decides
        // which kind this session (and the next prepared spare) uses.
        let vocabulary = Self.cappedVocabulary(vocabulary)
        let biasing = !vocabulary.isEmpty
        biasingWanted = biasing

        // Take the ready spare (the common, instant path); only build one inline if none is ready
        // (e.g. very fast back-to-back dictations before the background prepare finished) or the ready
        // one is the wrong kind because the vocabulary was added/cleared since it was prepared.
        let session: PreparedSession
        if let s = spare, s.transcriber.supportsBiasing == biasing { session = s; spare = nil }
        else if let s = await makePreparedSession(biasing: biasing) { spare = nil; session = s }
        else {
            Log.speech.error("beginSession: no analyzer session could be prepared")
            return nil
        }

        if biasing {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            do { try await session.analyzer.setContext(context) }
            catch { Log.speech.error("setContext (vocabulary biasing) failed: \(error.localizedDescription)") }
        }
        do { try await session.analyzer.start(inputSequence: session.stream) }
        catch {
            Log.speech.error("beginSession start failed: \(error.localizedDescription)")
            teardownActive()
            return nil
        }

        nextSessionID += 1
        let token = SessionToken(id: nextSessionID)
        self.analyzer = session.analyzer
        activeInput.withLock { $0 = ActiveInput(token: token, continuation: session.continuation) }

        // Per-session results task (ORA-CC-003). Ends when this session is torn down.
        switch session.transcriber {
        case .speech(let t): resultsTask = makeResultsTask(t.results)
        case .dictation(let t): resultsTask = makeResultsTask(t.results)
        }
        return token
    }

    /// Contextual strings are capped by the recognizer; an oversized array can drop the WHOLE set
    /// rather than the excess, so truncate loudly instead of silently losing every term.
    static let maxContextualStrings = 100
    static func cappedVocabulary(_ vocabulary: [String]) -> [String] {
        guard vocabulary.count > maxContextualStrings else { return vocabulary }
        Log.speech.notice("Vocabulary truncated to \(maxContextualStrings) terms (had \(vocabulary.count))")
        return Array(vocabulary.prefix(maxContextualStrings))
    }

    /// The single ordered results consumer, generic over the two transcriber kinds' result sequences.
    private func makeResultsTask<R: TranscriptResult>(
        _ results: some AsyncSequence<R, any Error> & Sendable
    ) -> Task<Void, Never> {
        Task { [weak self] in
            do {
                for try await result in results {
                    let text = String(result.text.characters)
                    guard let self else { break }
                    if result.isFinal { self.sink?.speechDidConfirm(text) }
                    else { self.sink?.speechDidReviseVolatile(text) }
                    DebugLog.transcript(text)
                }
            } catch {
                Log.speech.error("results stream ended with error: \(error.localizedDescription)")
            }
        }
    }

    /// Feed one converted buffer. `nonisolated` so the audio consumer forwards buffers without a
    /// per-buffer main-actor hop. `token` is the one `beginSession` returned for the stream this buffer
    /// came from: a buffer from a torn-down session is dropped rather than yielded into whatever
    /// session is live now.
    nonisolated public func feed(_ input: AnalyzerInput, for token: SessionToken) {
        activeInput.withLock { active in
            guard let active, active.token == token else { return }
            active.continuation.yield(input)
        }
    }

    /// Flush the volatile tail into confirmed text under a bounded timeout (ORA-ASR-003 / M3).
    /// Returns `true` if finalization completed within the cap, `false` if it timed out (the caller
    /// then parks the unfinalized tail in the recovery buffer, E7). Does NOT tear the session down —
    /// the caller drains late finals first, then calls `endSession()`.
    public func finalize(within cap: Duration) async -> Bool {
        guard let analyzer else { return true }
        // Signal end-of-input so finalization can complete. Leave the token in place: the bridge is
        // already drained by the caller, and clearing it here would be indistinguishable from teardown.
        activeInput.withLock { $0?.continuation.finish() }
        // Race finalize against a HARD timeout, resuming on whichever finishes first WITHOUT awaiting
        // the other. A wedged `analyzer.finalize` does not respond to cancellation, and awaiting it
        // (as `withTaskGroup` does) blocks forever — which froze the coordinator in `.finalizing`. If
        // the timeout wins we return `false`; the caller parks the tail in recovery and `endSession()`
        // discards the dead analyzer (its `cancelAndFinishNow` is fire-and-forget, so it can't wedge us).
        return await FinalizeRace.run(timeout: cap) {
            (try? await analyzer.finalize(through: nil)) != nil
        }
    }

    /// Tear the current session down completely so the NEXT dictation starts on a fresh analyzer.
    /// Used after a normal stop (post-drain), on a finalize timeout, and on cancel (ORA-SM-012).
    /// Nothing from this session can leak into the next: the results task is cancelled and the
    /// analyzer is finished. Also queues the next spare so the following start is instant.
    public func endSession() { teardown(queueingSpare: true) }

    /// Tear down the active session without queueing a spare (used internally: cancel, rewarm,
    /// shutdown, and the defensive call at the top of `beginSession`).
    private func teardownActive() { teardown(queueingSpare: false) }

    /// The single teardown. Both callers cancel the results task, finish the input, and finish the
    /// old analyzer; the ONLY difference is whether a fresh spare is queued afterwards.
    ///
    /// Note the ordering, which is load-bearing on the `endSession` path: the old analyzer is fully
    /// finished (bounded, so a wedged one cannot block forever) BEFORE the next spare is prepared, so
    /// teardown and fresh setup never run against the speech daemon concurrently — that concurrency is
    /// what let rapid-fire dictation wedge it. The insert step that follows usually covers the wait,
    /// so the spare is ready by the next start.
    private func teardown(queueingSpare: Bool) {
        resultsTask?.cancel(); resultsTask = nil
        finishActiveInput()
        let old = analyzer
        analyzer = nil
        Task { [weak self] in
            if let old { await Self.finishBounded(old) }
            if queueingSpare { self?.ensureSpare() }
        }
    }

    /// Finish and clear the live input under the lock, so a bridge task still yielding on another
    /// thread neither touches a released continuation nor reattaches to the next session.
    private func finishActiveInput() {
        activeInput.withLock { active in
            active?.continuation.finish()
            active = nil
        }
    }

    /// Await `cancelAndFinishNow` but never longer than `timeout` — a wedged analyzer never returns,
    /// and blocking on it is what let one bad session stall the next.
    private static func finishBounded(_ analyzer: SpeechAnalyzer) async {
        _ = await FinalizeRace.run(timeout: .seconds(3)) {
            await analyzer.cancelAndFinishNow(); return true
        }
    }

    /// Tear down any active session and clear warm state so the next `warmUp` rebuilds for `locale`.
    private func resetWarmState(for locale: Locale) {
        teardownActive()
        spare = nil
        modelReady = false
        inputFormat = nil
        self.locale = locale
    }

    /// Rebuild for a new locale (a Settings language change) without a relaunch. Throws
    /// `.modelUnavailable` if that locale's model isn't installed. Only when no session is active.
    public func rewarm(locale: Locale) async throws {
        guard locale.identifier != self.locale.identifier else { return }
        resetWarmState(for: locale)
        try await warmUp()
    }

    /// Switch to `locale`, first triggering the OS model install if it isn't present, then warming —
    /// all without a relaunch. Reports install progress (0 while already installed). Only when no
    /// session is active. `resetWarmState` updates the locale, so `makeTranscriber()` builds for the
    /// new locale when the model is reserved/installed.
    public func switchLocale(_ locale: Locale,
                             onProgress: @escaping @Sendable (Double) -> Void) async throws {
        if locale.identifier == self.locale.identifier && modelReady { return }
        resetWarmState(for: locale)
        if await modelStatus() != .installed {
            try await installModel(onProgress: onProgress)
        }
        try await warmUp()
    }
}
