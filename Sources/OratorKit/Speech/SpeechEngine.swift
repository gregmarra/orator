import Foundation
import AVFoundation
import Speech

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
    // The input continuation is written once on warmUp (main) and thereafter only `yield`-ed, which
    // is Sendable and thread-safe; exposing it nonisolated lets `feed` avoid a per-buffer main hop.
    nonisolated(unsafe) private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?

    /// The analyzer's chosen input format; AudioCapture converts to this.
    public private(set) var inputFormat: AVAudioFormat?

    /// Set by the coordinator before a session; results are delivered here in order.
    public weak var sink: SpeechResultSink?

    public init(locale: Locale) {
        self.locale = locale
    }

    // MARK: Model asset lifecycle (ORA-ASR-006 / E3–E4)

    private func makeTranscriber() -> SpeechTranscriber {
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
        let t = makeTranscriber()
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
        let t = makeTranscriber()
        // Reserve the locale so the asset stays resident once installed (R2).
        _ = try? await AssetInventory.reserve(locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [t]) else {
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

        let probe = makeTranscriber()
        self.inputFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [probe])
        modelReady = true
        spare = await makePreparedSession()   // ready so the FIRST dictation starts instantly
    }

    public var isWarm: Bool { modelReady && inputFormat != nil }

    // MARK: Per-session lifecycle (a fresh analyzer per dictation — clean boundaries)

    /// Build a fresh, fully-prepared session (the expensive `prepareToAnalyze` happens here, off the
    /// hotkey path). Returns nil if the model isn't ready.
    private func makePreparedSession() async -> PreparedSession? {
        guard let format = inputFormat else { return nil }
        let transcriber = makeTranscriber()
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
            let session = await self?.makePreparedSession()
            self?.spare = session
            self?.preparingSpare = false
        }
    }

    /// Start a dictation on a pre-prepared spare (instant): just apply vocabulary + `start`. Each
    /// dictation gets its OWN analyzer/transcriber/stream/results task, so no state can leak or drop
    /// across sessions (verified by `CrossSessionTests`).
    public func beginSession(vocabulary: [String]) async {
        guard modelReady else { return }
        teardownActive()   // defensive: never run two sessions on one analyzer

        // Take the ready spare (the common, instant path); only build one inline if none is ready
        // (e.g. very fast back-to-back dictations before the background prepare finished).
        let session: PreparedSession
        if let s = spare { session = s; spare = nil }
        else if let s = await makePreparedSession() { session = s }
        else { return }

        self.analyzer = session.analyzer
        self.inputContinuation = session.continuation

        if !vocabulary.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings = [.general: vocabulary]
            do { try await session.analyzer.setContext(context) }
            catch { Log.speech.error("setContext (vocabulary biasing) failed: \(error.localizedDescription)") }
        }
        do { try await session.analyzer.start(inputSequence: session.stream) }
        catch { Log.speech.error("beginSession start failed: \(error.localizedDescription)"); teardownActive(); return }

        // Per-session results task (ORA-CC-003). Ends when this session is torn down.
        let results = session.transcriber.results
        resultsTask = Task { [weak self] in
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
    /// per-buffer main-actor hop; only touches the Sendable continuation (ORA-CC-002 intent).
    nonisolated public func feed(_ input: AnalyzerInput) {
        inputContinuation?.yield(input)
    }

    /// Flush the volatile tail into confirmed text under a bounded timeout (ORA-ASR-003 / M3).
    /// Returns `true` if finalization completed within the cap, `false` if it timed out (the caller
    /// then parks the unfinalized tail in the recovery buffer, E7). Does NOT tear the session down —
    /// the caller drains late finals first, then calls `endSession()`.
    public func finalize(within cap: Duration) async -> Bool {
        guard let analyzer else { return true }
        inputContinuation?.finish()   // signal end-of-input so finalization can complete
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
    public func endSession() {
        resultsTask?.cancel(); resultsTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        let old = analyzer
        analyzer = nil
        // Serialize daemon work so rapid-fire dictation can't wedge it: fully finish the OLD analyzer
        // (bounded, so a wedged one can't block forever) BEFORE preparing the next spare — never run
        // teardown and fresh setup concurrently. The insert step that follows usually covers this, so
        // the spare is ready by the next start.
        Task { [weak self] in
            if let old { await Self.finishBounded(old) }
            self?.ensureSpare()
        }
    }

    /// Tear down the active session's objects without queueing a spare (used internally). Finishes the
    /// old analyzer fire-and-forget (callers here are one-off: cancel/rewarm/shutdown/defensive).
    private func teardownActive() {
        resultsTask?.cancel(); resultsTask = nil
        inputContinuation?.finish(); inputContinuation = nil
        if let analyzer { self.analyzer = nil; Task { await Self.finishBounded(analyzer) } }
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
