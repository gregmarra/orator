import AppKit

/// Subtle start/stop cues (§8.9). Respects the user's sound setting (ORA-FBK-003 / ORA-CFG-001).
/// Audio ducking (ORA-FBK-002) intentionally not in v1: off-by-default, intrusive, adds surface for
/// no required benefit.
@MainActor
/// Not `final`: the coordinator's terminal-feedback contract (success cue ONLY on a real insert) is a
/// behaviour worth asserting, and a test needs to both observe the cues and keep the suite silent.
public class SoundFeedback {
    private let startSound = NSSound(named: "Tink")
    private let stopSound = NSSound(named: "Pop")
    private let errorSound = NSSound(named: "Funk")

    public init() {}

    private var enabled: Bool { Settings.shared.soundEnabled }

    /// Play the start cue. Non-blocking: plays concurrently with capture start, never delaying the
    /// hotkey→capturing budget (M1 MUST > FBK-001 SHOULD). No-op when sound is disabled.
    public func playStart() {
        guard enabled, let sound = startSound else { return }
        sound.stop()
        sound.play()
    }

    public func playStop() {
        guard enabled else { return }
        stopSound?.play()
    }

    public func playError() {
        guard enabled else { return }
        errorSound?.play()
    }
}
