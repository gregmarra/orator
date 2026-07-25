import Foundation
@preconcurrency import AVFoundation

/// One-shot flag for the converter's input block.
private final class ConsumeOnce: @unchecked Sendable { var done = false }

/// Converts capture buffers (any input format) to a fixed analyzer output format, rebuilding the
/// underlying `AVAudioConverter` if the input format changes mid-stream (ORA-CAP-003).
///
/// **Why the status check is `!= .error`, not `== .haveData`:** feeding one buffer at a time, the
/// converter consumes that whole buffer, produces valid downsampled output, and *then* reports
/// `.inputRanDry` (no more input queued) — NOT `.haveData`. Gating on `.haveData` alone discards
/// every buffer, silently killing capture (no level, no analyzer input, no transcript). Verified by
/// `testConverterReportsInputRanDryYetProducesFrames`.
final class PCMConverter {
    private let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?

    init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }

    /// Convert one input buffer. Returns nil only on a hard converter error or an unusable input.
    func convert(_ pcm: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        // Rebuild when the input format changes. `AVAudioConverter.inputFormat` is the format it was
        // built from, so it doubles as the "current input format" without a shadow property.
        if converter?.inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: outputFormat)
            // Decimating 48 kHz → 16 kHz needs a steep anti-aliasing filter. At the default quality,
            // energy above 8 kHz folds back INTO the speech band as distortion — it doesn't just lose
            // detail, it corrupts what the recognizer hears. `.max` is the best filter available and
            // costs almost nothing on mono 16 kHz buffers, so it never trades against latency.
            converter?.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            // Belt and braces for multi-channel input. `AVCaptureAudioDataOutput` is asked for mono
            // (see `AudioCapture.monoFloatSettings`), so this should never fire — but if any device
            // ignores that request, `AVAudioConverter`'s implicit stereo→mono downmix produces
            // SILENCE rather than an error. Measured: averaging the channels transcribes NOTHING
            // (WER 1.00), while selecting one channel transcribes normally. Never leave the downmix
            // implicit.
            if pcm.format.channelCount > outputFormat.channelCount {
                converter?.channelMap = (0..<Int(outputFormat.channelCount)).map { NSNumber(value: $0) }
            }
        }
        guard let converter, pcm.frameLength > 0 else { return nil }

        let ratio = outputFormat.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        let once = ConsumeOnce()
        let status = converter.convert(to: out, error: nil) { _, inStatus in
            if once.done { inStatus.pointee = .noDataNow; return nil }
            once.done = true
            inStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, out.frameLength > 0 else { return nil }
        return out
    }

    /// Absolute peak sample (0…1), for clipping detection. Unlike `rms` this is NOT floored or
    /// compressed — clipping is about individual samples hitting the rails, which an averaged level
    /// hides completely: a clipped signal and a merely loud one have almost the same RMS.
    static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var peak: Float = 0
        if let data = buffer.floatChannelData {
            let ch = data[0]
            for i in 0..<n { peak = max(peak, abs(ch[i])) }
        } else if let data = buffer.int16ChannelData {
            let ch = data[0], scale: Float = 1.0 / 32768.0
            for i in 0..<n { peak = max(peak, abs(Float(ch[i]) * scale)) }
        } else if let data = buffer.int32ChannelData {
            let ch = data[0], scale: Float = 1.0 / 2147483648.0
            for i in 0..<n { peak = max(peak, abs(Float(ch[i]) * scale)) }
        }
        return min(peak, 1)
    }

    /// A sample this close to full scale is at the rails. Digital clipping flattens waveform peaks
    /// into square edges, which the recognizer hears as broadband distortion — no downstream setting
    /// recovers it, so the only fix is turning the gain down.
    static let clippingThreshold: Float = 0.99

    /// Normalized RMS level (0…1, −50 dB floor) for the waveform meter. Format-agnostic: the analyzer's
    /// preferred format is often Int16 (not Float32), so reading only `floatChannelData` would return
    /// nil → a permanently flat waveform even while audio flows. Handle Int16/Int32 too.
    static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let data = buffer.floatChannelData {
            let ch = data[0]
            for i in 0..<n { let s = ch[i]; sum += s * s }
        } else if let data = buffer.int16ChannelData {
            let ch = data[0], scale: Float = 1.0 / 32768.0
            for i in 0..<n { let s = Float(ch[i]) * scale; sum += s * s }
        } else if let data = buffer.int32ChannelData {
            let ch = data[0], scale: Float = 1.0 / 2147483648.0
            for i in 0..<n { let s = Float(ch[i]) * scale; sum += s * s }
        } else {
            return 0
        }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }
}
