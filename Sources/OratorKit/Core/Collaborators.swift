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

extension AudioCapture: AudioSource {}
extension TextInserter: TextInserting {}
