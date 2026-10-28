import XCTest
@preconcurrency import AVFoundation
import Speech
@testable import OratorKit

// Shared fixtures, stand-ins and rig builders.
//
// These were copy-pasted across four test files, and the copies had already drifted: three different
// post-finalize sleeps (200/400/600 ms), three ways of building a coordinator, and two sets of
// functionally identical stubs. Divergent copies of a fixture make tests flaky for reasons that have
// nothing to do with the code under test. Internal (not private/fileprivate) so every test file in the
// target can share one definition.

// MARK: - Fixtures

/// A warmed en-US engine, or a skip when the model isn't installed on this host. Owns that
/// precondition so it isn't restated at every call site.
@MainActor
func warmEngine() async throws -> SpeechEngine {
    let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
    let status = await engine.modelStatus()
    try XCTSkipUnless(status == .installed, "en-US model not installed on this host")
    try await engine.warmUp()
    return engine
}

/// Synthesize `phrase` to an audio file with `say`, or skip when `say` is unavailable.
func sayToFile(_ phrase: String, _ name: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-o", url.path, phrase]
    try say.run()
    say.waitUntilExit()
    try XCTSkipUnless(say.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path),
                      "`say` unavailable")
    return url
}

/// Drive one dictation through the engine from a file and return the confirmed transcript, lowercased.
///
/// `realtime: true` is load-bearing, not decoration: fed flat out the analyzer returns NOTHING, which
/// once made a guard-test pass for the wrong reason.
@MainActor
func transcribe(_ url: URL, through engine: SpeechEngine) async throws -> String {
    let collector = TranscriptCollector()
    engine.sink = collector
    let capture = FileAudioCapture(url: url, realtime: true)
    let stream = try capture.start(outputFormat: try XCTUnwrap(engine.inputFormat))
    let started = await engine.beginSession()
    let token = try XCTUnwrap(started, "beginSession must report a started session")
    let bridge = Task.detached { [engine] in for await input in stream { engine.feed(input, for: token) } }
    await bridge.value                          // drains when the file hits EOF
    _ = await engine.finalize(within: .seconds(5))
    try await Task.sleep(for: .milliseconds(600))   // let late finals arrive
    let text = collector.confirmed.lowercased()
    engine.endSession()
    return text
}

/// Accumulates confirmed transcript for the file-driven tests.
@MainActor
final class TranscriptCollector: SpeechResultSink {
    private(set) var confirmed = ""
    func speechDidConfirm(_ text: String) {
        if !confirmed.isEmpty { confirmed += " " }
        confirmed += text
    }
    func speechDidReviseVolatile(_ text: String) {}
}

// MARK: - Stand-ins

/// An audio source that starts cleanly and produces no buffers, letting a test decide exactly when
/// capture "dies".
///
/// Models the REAL `AudioCapture` on the two points the watchdog depends on: a successful `start`
/// clears the stall (real capture reseeds its buffer clock, so a failover genuinely buys another full
/// budget — a stub that stayed stalled would drive a rapid-fire cascade hardware cannot produce), and
/// device UIDs honour the failover exclusion set.
@MainActor
final class StubAudio: AudioSource {
    var currentLevel: Float = 0
    var onUnrecoverableFailure: (@Sendable (String) -> Void)?
    /// Seconds of silence to report. `start` resets it, mirroring the real clock reseed.
    var stallSeconds: TimeInterval = 0
    var hasDeliveredAudio = true
    var throwOnStart: Error?
    /// UIDs this stub can hand out, in preference order; `start` picks the first not excluded.
    var availableUIDs: [String] = ["mic-a", "mic-b"]
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var excludedOnLastStart: Set<String> = []
    private(set) var currentDeviceUID: String?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var running = false

    var secondsSinceLastBuffer: TimeInterval? { running ? stallSeconds : nil }

    func start(outputFormat: AVAudioFormat, excluding: Set<String>) throws -> AsyncStream<AnalyzerInput> {
        excludedOnLastStart = excluding
        if let throwOnStart { throw throwOnStart }
        // Only excluded devices left ⇒ the same signal real capture gives (ORA-CAP-006).
        guard let uid = availableUIDs.first(where: { !excluding.contains($0) }) else {
            throw AudioCapture.CaptureError.noInputDevice
        }
        currentDeviceUID = uid
        startCount += 1
        running = true
        stallSeconds = 0            // a fresh session restarts the watchdog budget, as real capture does
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        return stream
    }

    func stop() {
        guard running else { return }
        stopCount += 1
        running = false
        currentDeviceUID = nil
        continuation?.finish()
        continuation = nil
    }
}

/// Returns a scripted outcome and records what it was asked to insert — crucially, it never posts a
/// real CGEvent ⌘V, so the suite can't paste into whatever app is frontmost.
@MainActor
final class StubInserter: TextInserting {
    var outcome: InsertionOutcome = .inserted
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String, into target: TargetContext,
                accessibilityGranted: Bool) async -> InsertionOutcome {
        insertedTexts.append(text)
        return outcome
    }
}

/// A scriptable recognizer: no model, no analyzer, and every engine interleaving the coordinator has to
/// survive available on demand — a `beginSession` that stays suspended until released, one that fails,
/// a `finalize` that times out, and results delivered exactly when the test says.
///
/// Models the real engine's contract, not its machinery: `endSession` tears down whatever session is
/// live AT THAT MOMENT, so a session begun after the coordinator's teardown stays live (`liveToken`
/// non-nil) unless someone reaps it — precisely the leak ORA-SM-014 is about.
@MainActor
final class StubEngine: SpeechTranscribing {
    var isWarm = true
    var inputFormat: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    weak var sink: SpeechResultSink?
    /// What `modelStatus()` reports — decides whether a failed start blames the model.
    var status: ModelStatus = .installed

    /// When set, `beginSession` parks until `resumeBegin()` — the suspension point a second hotkey
    /// press can land in.
    var suspendBegin = false
    /// When set, `beginSession` reports a failed start (nil).
    var failBegin = false
    /// What `finalize` returns; `false` is a finalization timeout (ORA-ASR-003).
    var finalizeSucceeds = true
    /// Runs inside `finalize`, where a real engine flushes its tail — the hook for late finals.
    var onFinalize: (@MainActor (StubEngine) -> Void)?

    private(set) var beginCount = 0
    private(set) var finalizeCount = 0
    private(set) var endCount = 0
    /// The session begun and not yet torn down. Non-nil once the coordinator is idle means a leak.
    private(set) var liveToken: SpeechEngine.SessionToken?
    var isBeginSuspended: Bool { pendingBegin != nil }
    private var pendingBegin: CheckedContinuation<Void, Never>?
    private var nextID: UInt64 = 0

    func modelStatus() async -> ModelStatus { status }

    func beginSession() async -> SpeechEngine.SessionToken? {
        beginCount += 1
        if suspendBegin { await withCheckedContinuation { pendingBegin = $0 } }
        guard !failBegin else { return nil }
        nextID += 1
        let token = SpeechEngine.SessionToken(id: nextID)
        liveToken = token
        return token
    }

    /// Release a `beginSession` parked by `suspendBegin`.
    func resumeBegin() {
        pendingBegin?.resume()
        pendingBegin = nil
    }

    /// StubAudio produces no buffers, so there is never anything to feed.
    nonisolated func feed(_ input: AnalyzerInput, for token: SpeechEngine.SessionToken) {}

    func finalize(within cap: Duration) async -> Bool {
        finalizeCount += 1
        onFinalize?(self)
        return finalizeSucceeds
    }

    /// When set, the engine reports the real engine's end-of-results signal: `awaitResultsDrained`
    /// returns once every `confirmLater` delivery has landed. Off by default, so the coordinator
    /// falls back to polling the drain.
    var resultsDrainSignal = false
    private var pendingDeliveries: [Task<Void, Never>] = []
    func awaitResultsDrained(within cap: Duration) async -> Bool {
        guard resultsDrainSignal else { return false }
        for delivery in pendingDeliveries { await delivery.value }
        return true
    }

    func endSession() {
        endCount += 1
        liveToken = nil
    }

    /// Deliver a final now, as the results task would.
    func confirm(_ text: String) { sink?.speechDidConfirm(text) }
    /// Revise the volatile tail now.
    func revise(_ text: String) { sink?.speechDidReviseVolatile(text) }
    /// Deliver a final on a LATER main-actor turn, `delay` from now, the way the real results task
    /// delivers flushed finals after `finalize` returns: called from `onFinalize`, it lands inside the
    /// coordinator's drain. A small nonzero delay is what tells a real drain (~30 ms+) from one that
    /// collapsed to nothing.
    func confirmLater(_ text: String, after delay: Duration = .zero) {
        pendingDeliveries.append(Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            self?.confirm(text)
        })
    }
}

@MainActor
final class FakePermissions: PermissionsManager {
    var mic = true
    var accessibility = true
    override var microphoneGranted: Bool { mic }
    override var accessibilityGranted: Bool { accessibility }
}

/// Silences the suite and records which cues fired — the terminal-feedback contract is the behaviour
/// under test, not a side effect.
final class SpyFeedback: SoundFeedback, @unchecked Sendable {
    enum Cue: Equatable { case start, stop, error, nothingHeard }
    private(set) var cues: [Cue] = []
    override func playStart() { cues.append(.start) }
    override func playStop() { cues.append(.stop) }
    override func playError() { cues.append(.error) }
    override func playNothingHeard() { cues.append(.nothingHeard) }
}

// MARK: - Coordinator rig

@MainActor
struct Rig {
    let coordinator: SessionCoordinator
    let audio: StubAudio
    let inserter: StubInserter
    let permissions: FakePermissions
    let feedback: SpyFeedback
    let recovery: RecoveryBuffer
}

/// A coordinator wired to stand-ins, on a warm engine. `now` is injectable for the error-expiry tests.
@MainActor
func makeRig(now: @escaping @MainActor () -> Date = { Date() }) async throws -> Rig {
    makeRig(engine: try await warmEngine(), now: now)
}

/// A coordinator wired to stand-ins on whatever `engine` the test supplies — a `StubEngine` needs no
/// speech model. Timing, clock and target capture default to production.
@MainActor
func makeRig(engine: any SpeechTranscribing,
             timing: CoordinatorTiming = CoordinatorTiming(),
             now: @escaping @MainActor () -> Date = { Date() },
             captureTarget: @escaping @MainActor () -> TargetContext? = { TargetContext.capture() }) -> Rig {
    let audio = StubAudio()
    let inserter = StubInserter()
    let permissions = FakePermissions()
    let feedback = SpyFeedback()
    let recovery = RecoveryBuffer()
    let coordinator = SessionCoordinator(audio: audio, engine: engine, inserter: inserter,
                                         recovery: recovery, permissions: permissions,
                                         feedback: feedback, timing: timing, now: now,
                                         captureTarget: captureTarget)
    return Rig(coordinator: coordinator, audio: audio, inserter: inserter,
               permissions: permissions, feedback: feedback, recovery: recovery)
}

/// Poll until `condition` holds (or the timeout passes), for waiting on a state the test can't await
/// directly — e.g. "the start is now parked inside `beginSession`".
@MainActor
func waitFor(timeoutMs: Int = 2000, _ condition: () -> Bool) async {
    var waited = 0
    while !condition(), waited < timeoutMs {
        try? await Task.sleep(for: .milliseconds(10))
        waited += 10
    }
}

/// Let the coordinator's `Task { await startRecording() }` (and friends) run to completion.
@MainActor
func settle(_ ms: Int = 250) async {
    try? await Task.sleep(for: .milliseconds(ms))
}

/// Wait for the session to return to `.idle`, then hand back control immediately. Needed for any
/// assertion about `notice`, which is deliberately transient (~1.6 s) — a fixed long sleep would race
/// the notice's own expiry and read nil for the wrong reason.
@MainActor
func waitUntilIdle(_ coordinator: SessionCoordinator, timeoutMs: Int = 6000) async {
    var waited = 0
    while coordinator.state != .idle, waited < timeoutMs {
        try? await Task.sleep(for: .milliseconds(50))
        waited += 50
    }
}
