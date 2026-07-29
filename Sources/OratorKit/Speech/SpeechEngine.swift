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
        let transcriber: SpeechTranscriber
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

    public init(locale: Locale) {
        self.locale = locale
    }

    // MARK: Model asset lifecycle (ORA-ASR-006 / E3–E4)

    /// Orator runs on `SpeechTranscriber` unconditionally — the newest, most accurate module.
    ///
    /// The alternative, `DictationTranscriber`, is the only module that honours
    /// `AnalysisContext.contextualStrings`, so recognition biasing requires it. We deliberately don't
    /// take that trade: Apple documents that DictationTranscriber "uses the same speech-to-text
    /// machine learning models as system dictation features do", i.e. the older lineage, while
    /// SpeechTranscriber is the model shipped for Notes/Voice Memos/Journal. Running the better model
    /// unconditionally IS the product; a vocabulary feature that silently downgrades it is not worth
    /// having. (Independent LibriSpeech numbers put the new module at 2.12%/4.56% WER against
    /// 9.02%/16.25% for the legacy one — the gap is large and the biasing gain is not.)
    private func makeSpeechTranscriber() -> SpeechTranscriber {
        // Streaming preset with volatile results for the live preview (ORA-IND-010) and native
        // punctuation preserved (ORA-ASR-007). No etiquette/disfluency stripping (ORA-VOC-004).
        SpeechTranscriber(locale: locale,
                          transcriptionOptions: [],
                          reportingOptions: [.volatileResults],
                          attributeOptions: [])
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
        let modules: [any SpeechModule] = [makeSpeechTranscriber()]
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

        self.inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [makeSpeechTranscriber()])
        modelReady = true
        spare = await makePreparedSession()   // ready so the FIRST dictation starts instantly
    }

    public var isWarm: Bool { modelReady && inputFormat != nil }

    // MARK: Per-session lifecycle (a fresh analyzer per dictation — clean boundaries)

    /// Build a fresh, fully-prepared session (the expensive `prepareToAnalyze` happens here, off the
    /// hotkey path). Returns nil if the model isn't ready.
    private func makePreparedSession() async -> PreparedSession? {
        guard let format = inputFormat else { return nil }
        return await prepare(makeSpeechTranscriber(), format: format)
    }

    private func prepare(_ transcriber: SpeechTranscriber, format: AVAudioFormat) async -> PreparedSession? {
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
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
            let session = await self.makePreparedSession()
            self.spare = session
            self.preparingSpare = false
        }
    }

    /// Start a dictation on a pre-prepared spare (instant): just `start`. Each dictation gets its OWN
    /// analyzer/transcriber/stream/results task, so no state can leak or drop across sessions
    /// (verified by `CrossSessionTests`).
    /// Returns the token identifying the started session, or **nil** if the session could not be
    /// started (model not ready, no preparable analyzer, `start` threw). A nil return MUST be treated
    /// as a failed start: without it the caller would show a live indicator over a session that has no
    /// transcriber attached and silently discard every buffer (ORA-REL-001).
    @discardableResult
    public func beginSession() async -> SessionToken? {
        guard modelReady else {
            Log.speech.error("beginSession: model not ready")
            return nil
        }
        teardownActive()   // defensive: never run two sessions on one analyzer

        // Take the ready spare (the common, instant path); only build one inline if none is ready —
        // e.g. very fast back-to-back dictations before the background prepare finished.
        let session: PreparedSession
        if let s = spare { session = s; spare = nil }
        else if let s = await makePreparedSession() { session = s }
        else {
            Log.speech.error("beginSession: no analyzer session could be prepared")
            return nil
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
        resultsTask = makeResultsTask(session.transcriber.results)
        return token
    }

    /// The single ordered results consumer.
    private func makeResultsTask(
        _ results: some AsyncSequence<SpeechTranscriber.Result, any Error> & Sendable
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
