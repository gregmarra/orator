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
func warmEngine(biasing: Bool = false) async throws -> SpeechEngine {
    let engine = SpeechEngine(locale: Locale(identifier: "en-US"), biasing: biasing)
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
func transcribe(_ url: URL, through engine: SpeechEngine, vocabulary: [String] = []) async throws -> String {
    let collector = TranscriptCollector()
    engine.sink = collector
    let capture = FileAudioCapture(url: url, realtime: true)
    let stream = try capture.start(outputFormat: try XCTUnwrap(engine.inputFormat))
    let started = await engine.beginSession(vocabulary: vocabulary)
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
    func reset() { confirmed = "" }
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
    let engine = try await warmEngine()
    let audio = StubAudio()
    let inserter = StubInserter()
    let permissions = FakePermissions()
    let feedback = SpyFeedback()
    let recovery = RecoveryBuffer()
    let coordinator = SessionCoordinator(audio: audio, engine: engine, inserter: inserter,
                                         recovery: recovery, permissions: permissions,
                                         feedback: feedback, now: now)
    return Rig(coordinator: coordinator, audio: audio, inserter: inserter,
               permissions: permissions, feedback: feedback, recovery: recovery)
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
