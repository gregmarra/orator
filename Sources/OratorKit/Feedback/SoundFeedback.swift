import AppKit
import AVFoundation

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
    /// Synthesized rather than a system sound: nothing in the stock set is a quiet *descending* tone,
    /// and the nearest error sounds are all far louder than this outcome deserves (see `playNothingHeard`).
    private let nothingHeardSound = SoundFeedback.fallingTone()

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

    /// "I heard nothing" — a soft falling tone, deliberately NOT the error sound.
    ///
    /// Nothing went wrong here: the user simply didn't say anything, or said it too quietly. The
    /// system error sound is loud and alarming, which overstated a benign outcome every time. A gentle
    /// descent is the natural inverse of the rising start cue: recording opened, nothing came back.
    public func playNothingHeard() {
        guard enabled else { return }
        nothingHeardSound?.stop()
        nothingHeardSound?.play()
    }

    // MARK: Synthesis

    /// A quarter-second tone gliding down an octave, at low amplitude with a smooth attack and decay.
    ///
    /// Built as an in-memory WAV and handed to `NSSound`. Deliberately NOT `AVAudioEngine`: starting
    /// one corrupts the Swift main-actor executor identity process-wide on this toolchain, which
    /// crashes SwiftUI (see the note in `AudioCapture`) — a cue sound is nowhere near worth that risk.
    private static func fallingTone(from startHz: Double = 740, to endHz: Double = 370,
                                    seconds: Double = 0.24, amplitude: Double = 0.16) -> NSSound? {
        let sampleRate = 44100.0
        let frameCount = Int(sampleRate * seconds)
        var samples = [Int16](repeating: 0, count: frameCount)
        // Integrate the frequency glide rather than recomputing `sin(2π·f(t)·t)`, which would jump in
        // phase as f changes and click audibly.
        var phase = 0.0
        for i in 0..<frameCount {
            let t = Double(i) / Double(frameCount)
            let frequency = startHz + (endHz - startHz) * t
            phase += 2 * .pi * frequency / sampleRate
            // Raised-cosine envelope: zero at both ends, so there is no click on start or stop.
            let envelope = 0.5 - 0.5 * cos(2 * .pi * t)
            samples[i] = Int16(sin(phase) * envelope * amplitude * Double(Int16.max))
        }
        return NSSound(data: wav(samples, sampleRate: Int(sampleRate)))
    }

    /// Minimal 16-bit mono PCM WAV container around `samples`.
    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2, channels = 1
        let dataBytes = samples.count * bytesPerSample
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        append(UInt32(16))                                              // PCM header size
        append(UInt16(1))                                               // format: PCM
        append(UInt16(channels))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * channels * bytesPerSample))          // byte rate
        append(UInt16(channels * bytesPerSample))                       // block align
        append(UInt16(bytesPerSample * 8))                              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataBytes))
        for sample in samples { append(sample) }
        return data
    }
}
