import AppKit
import AVFoundation

/// Subtle start/stop cues (§8.9). Respects the user's sound setting (ORA-FBK-003 / ORA-CFG-001).
/// Audio ducking (ORA-FBK-002) intentionally not in v1: off-by-default, intrusive, adds surface for
/// no required benefit.
///
/// The three dictation cues are ONE sound at three pitches — the system "Tink", played as-is to start,
/// slightly lower to confirm an insert, and a full octave down when nothing was heard. Relatedness is
/// the point: they read as one family, and pitch alone says which outcome it was, so no cue has to be
/// loud or alarming to be distinguishable. Failures still get the system error sound, which should
/// sound like an intrusion because it is one.
@MainActor
/// Not `final`: the coordinator's terminal-feedback contract (success cue ONLY on a real insert) is a
/// behaviour worth asserting, and a test needs to both observe the cues and keep the suite silent.
public class SoundFeedback {
    private let startSound = NSSound(named: "Tink")
    /// A touch below the start cue: clearly the same sound, clearly the other end of the dictation.
    private let stopSound = SoundFeedback.tink(pitch: 0.85) ?? NSSound(named: "Pop")
    /// A full octave down. Nothing went wrong — the user simply didn't say anything, or said it too
    /// quietly — so this must NOT be the error sound, which is loud and alarming for a benign outcome.
    private let nothingHeardSound = SoundFeedback.tink(pitch: 0.5) ?? NSSound(named: "Bottle")
    private let errorSound = NSSound(named: "Funk")

    public init() {}

    private var enabled: Bool { Settings.shared.soundEnabled }

    /// Play a cue, restarting it if it's already sounding so rapid dictations don't swallow their own
    /// feedback. Non-blocking: a cue never delays the hotkey→capturing budget (M1 MUST > FBK-001
    /// SHOULD). No-op when the user has sound off.
    private func play(_ sound: NSSound?) {
        guard enabled, let sound else { return }
        sound.stop()
        sound.play()
    }

    public func playStart() { play(startSound) }
    public func playStop() { play(stopSound) }
    /// "I heard nothing" — the start cue an octave down, deliberately not the error sound.
    public func playNothingHeard() { play(nothingHeardSound) }
    public func playError() { play(errorSound) }

    // MARK: Deriving the family from one system sound

    /// The system Tink, resampled. `pitch` is a frequency multiplier: 0.5 is an octave down.
    ///
    /// Resampling shifts pitch and duration together, the way slowing a tape does, which is what keeps
    /// the result recognisably the same sound rather than a synthesized approximation of it. Reading
    /// the OS file at launch also means there is no audio asset to ship or keep in sync.
    ///
    /// Deliberately NOT `AVAudioEngine`: starting one corrupts the Swift main-actor executor identity
    /// process-wide on this toolchain, which crashes SwiftUI (see the note in `AudioCapture`). Nowhere
    /// near worth it for a cue sound. `AVAudioFile` alone is fine — it is the engine that is poison.
    private static func tink(pitch: Double) -> NSSound? {
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff")
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channel = buffer.floatChannelData else { return nil }

        let source = (0..<Int(buffer.frameLength)).map { channel[0][$0] }   // one channel is enough for a cue
        guard source.count > 1, pitch > 0 else { return nil }
        // Lower pitch ⇒ more output frames for the same source, hence the divide.
        let count = Int(Double(source.count) / pitch)
        var out = [Float](repeating: 0, count: count)
        for j in 0..<count {
            let x = Double(j) * pitch
            let i = Int(x)
            guard i + 1 < source.count else { break }
            let fraction = Float(x - Double(i))    // linear interpolation between neighbouring samples
            out[j] = (source[i] * (1 - fraction) + source[i + 1] * fraction) * 0.9   // a touch under the source
        }
        return NSSound(data: wav(out, sampleRate: format.sampleRate))
    }

    /// Minimal 16-bit mono PCM WAV container, so the resampled audio can go straight to `NSSound`.
    private static func wav(_ samples: [Float], sampleRate: Double) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let dataBytes = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8));      append(UInt32(36 + dataBytes))
        data.append(contentsOf: Array("WAVEfmt ".utf8));  append(UInt32(16))   // PCM header size
        append(UInt16(1))                                                      // format: PCM
        append(UInt16(1))                                                      // channels
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))                                         // byte rate
        append(UInt16(2))                                                      // block align
        append(UInt16(16))                                                     // bits per sample
        data.append(contentsOf: Array("data".utf8));      append(UInt32(dataBytes))
        for sample in samples { append(Int16(max(-1, min(1, sample)) * Float(Int16.max))) }
        return data
    }
}
