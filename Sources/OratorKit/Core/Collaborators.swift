import AVFoundation
import Speech

/// The audio source `SessionCoordinator` drives.
///
/// A protocol rather than the concrete `AudioCapture` so the state machine — which owns every
/// ORA-SM/ORA-ACT requirement and is the subtlest code in the app — can be exercised headlessly. The
/// substitutable implementation already existed (`FileAudioCapture`, which replays a file through the
/// *same* `PCMConverter`); it just had no way in.
@MainActor
public protocol AudioSource: AnyObject {
    /// Latest audio level (0…1), polled by the coordinator's UI tick.
    var currentLevel: Float { get }
    /// Seconds since a buffer last arrived, or nil when not running — the capture watchdog's input.
    var secondsSinceLastBuffer: TimeInterval? { get }
    /// Whether any audio has arrived yet this session, so the watchdog can tell a device that is still
    /// waking up from one that was working and died.
    var hasDeliveredAudio: Bool { get }
    /// When the current capture delivered its first buffer — the moment the mic was really live, which
    /// `start` returning is not (device wake-up happens after it). Latency instrumentation only.
    var firstBufferAt: ContinuousClock.Instant? { get }
    /// Called when capture cannot continue, so the coordinator aborts rather than leave a dead-mic
    /// recording (ORA-REL-001).
    var onUnrecoverableFailure: (@Sendable (String) -> Void)? { get set }

    /// Begin capture. `excluding` holds UIDs that have already failed during this dictation; device
    /// resolution MUST skip them, so a mid-dictation failover cannot re-select the microphone that
    /// just died. Throws `noInputDevice` when only excluded devices remain — the signal that there is
    /// nowhere left to fail over to.
    func start(outputFormat: AVAudioFormat, excluding: Set<String>) throws -> AsyncStream<AnalyzerInput>
    func stop()
    /// UID of the device capture is currently using, so a failed one can be excluded from the retry.
    var currentDeviceUID: String? { get }
}

public extension AudioSource {
    var firstBufferAt: ContinuousClock.Instant? { nil }

    func start(outputFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        try start(outputFormat: outputFormat, excluding: [])
    }
}

/// The insertion step `SessionCoordinator` delegates to.
///
/// Also a protocol for testability, but for a sharper reason than `AudioSource`: the real
/// `TextInserter` posts a genuine CGEvent ⌘V to the HID tap, so ANY coordinator test that reached it
/// would paste into whatever app happened to be frontmost on the developer's machine.
@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String, into target: TargetContext,
                accessibilityGranted: Bool) async -> InsertionOutcome
}


/// The recognizer `SessionCoordinator` drives — exactly the slice of `SpeechEngine` it uses, and no
/// more (model install, locale switching and warm-up stay on the concrete engine, owned by the app).
///
/// A protocol so the coordinator's tests no longer depend on the on-device model: without the en-US
/// asset every coordinator test used to skip silently, and even with it the riskiest engine
/// interleavings — a `beginSession` still suspended when the user stops, a `finalize` that times out,
/// a final that lands mid-drain — could not be produced on demand. `Sendable` because the audio bridge
/// captures it into a detached task to call `feed` (which is also why `SpeechEngine` declares the
/// conformance in its own file: a Sendable conformance can't be added retroactively).
@MainActor
public protocol SpeechTranscribing: AnyObject, Sendable {
    /// Model resident and input format known, so a session can start without a load.
    var isWarm: Bool { get }
    /// The format capture must convert to; nil until warm.
    var inputFormat: AVAudioFormat? { get }
    /// Receives results in order (ORA-CC-003). Held weakly by the real engine.
    var sink: SpeechResultSink? { get set }

    func modelStatus() async -> ModelStatus
    /// Start one dictation's session; nil means it could NOT be started and must be treated as a
    /// failed start (ORA-REL-001).
    func beginSession() async -> SpeechEngine.SessionToken?
    /// Feed one converted buffer from the audio bridge, off the main actor. Buffers carrying a token
    /// other than the live session's are dropped.
    nonisolated func feed(_ input: AnalyzerInput, for token: SpeechEngine.SessionToken)
    /// Flush the volatile tail under `cap`; `false` means it timed out (ORA-ASR-003).
    func finalize(within cap: Duration) async -> Bool
    /// Tear down whatever session is live now.
    func endSession()
}

extension AudioCapture: AudioSource {}
extension TextInserter: TextInserting {}
