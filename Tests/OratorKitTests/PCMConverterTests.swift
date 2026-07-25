import XCTest
@preconcurrency import AVFoundation
@testable import OratorKit

/// `PCMConverter.rms` drives BOTH user-visible level surfaces — the indicator waveform and the
/// Settings level bar — and its doc comment records a real shipped bug: the analyzer's preferred
/// format is often Int16, so a Float32-only implementation returned nil and the meter stayed flat
/// while audio flowed. The hand-written per-format scale factors are exactly what regresses silently,
/// and it is a pure function over a buffer: no hardware, no actor, no timing.
final class PCMConverterRMSTests: XCTestCase {

    /// Fill a buffer of `commonFormat` with a full-scale-relative sine at `amplitude` (0…1).
    private func sineBuffer(_ commonFormat: AVAudioCommonFormat,
                            amplitude: Float, frames: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: 16000,
                                                 channels: 1, interleaved: false))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buf.frameLength = frames
        // Exactly 8 whole cycles over the buffer, so every format sees an identical waveform and the
        // RMS comparison below isn't measuring a phase difference.
        func sample(_ i: Int) -> Float {
            amplitude * sinf(2 * .pi * 8 * Float(i) / Float(frames))
        }
        for i in 0..<Int(frames) {
            let s = sample(i)
            switch commonFormat {
            case .pcmFormatFloat32: buf.floatChannelData![0][i] = s
            case .pcmFormatInt16:   buf.int16ChannelData![0][i] = Int16(s * 32767)
            case .pcmFormatInt32:   buf.int32ChannelData![0][i] = Int32(s * 2_147_483_000)
            default: XCTFail("unsupported test format"); return buf
            }
        }
        return buf
    }

    /// THE regression guard for the flat-waveform bug: the same audio must read the same level
    /// regardless of the sample format the capture session hands us.
    func testLevelAgreesAcrossSampleFormats() throws {
        let float = PCMConverter.rms(try sineBuffer(.pcmFormatFloat32, amplitude: 0.25))
        let int16 = PCMConverter.rms(try sineBuffer(.pcmFormatInt16, amplitude: 0.25))
        let int32 = PCMConverter.rms(try sineBuffer(.pcmFormatInt32, amplitude: 0.25))

        XCTAssertGreaterThan(float, 0, "a real signal must not read as silence")
        XCTAssertEqual(int16, float, accuracy: 0.05, "Int16 buffers must not read flat (the shipped bug)")
        XCTAssertEqual(int32, float, accuracy: 0.05, "Int32 buffers must not read flat")
    }

    /// Louder audio must read higher — the scale factors could agree across formats yet still be wrong.
    func testLevelIsMonotonicInAmplitude() throws {
        let quiet = PCMConverter.rms(try sineBuffer(.pcmFormatFloat32, amplitude: 0.05))
        let loud = PCMConverter.rms(try sineBuffer(.pcmFormatFloat32, amplitude: 0.5))
        XCTAssertGreaterThan(loud, quiet)
    }

    /// Digital silence clamps to the -50 dB floor, not to a negative or NaN value.
    func testSilenceReadsZero() throws {
        let silent = try sineBuffer(.pcmFormatFloat32, amplitude: 0)
        XCTAssertEqual(PCMConverter.rms(silent), 0)
    }

    /// Full-scale audio saturates at 1 rather than overshooting the bar's 0…1 contract.
    func testFullScaleClampsToOne() throws {
        let hot = try sineBuffer(.pcmFormatFloat32, amplitude: 1.0)
        let level = PCMConverter.rms(hot)
        XCTAssertLessThanOrEqual(level, 1.0)
        XCTAssertGreaterThan(level, 0.9)
    }

    /// An empty buffer must return 0 WITHOUT dereferencing the channel pointers.
    func testEmptyBufferReturnsZeroWithoutReadingChannels() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                                 channels: 1, interleaved: false))
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buf.frameLength = 0
        XCTAssertEqual(PCMConverter.rms(buf), 0)
    }
}

/// A stereo USB microphone (Yeti X, Brio 505) delivers **2 ch, 48 kHz, Float32, deinterleaved**.
/// Converting that to the analyzer's mono format silently produced SILENCE: `convert` returned a
/// full-length buffer and reported no error, so every surface looked healthy — capture running, raw
/// level meter moving — while the recognizer received nothing but zeros. Dictation on any stereo mic
/// was dead, and only stereo mics were affected, which is why the built-in (mono) mic always worked.
final class PCMConverterDownmixTests: XCTestCase {

    private func stereoBuffer(commonFormat: AVAudioCommonFormat, interleaved: Bool,
                              sampleRate: Double = 48000) throws -> AVAudioPCMBuffer {
        let fmt = try XCTUnwrap(AVAudioFormat(commonFormat: commonFormat, sampleRate: sampleRate,
                                              channels: 2, interleaved: interleaved))
        let frames: AVAudioFrameCount = 4800
        let buf = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames))
        buf.frameLength = frames
        func s(_ i: Int) -> Float { sinf(2 * .pi * 8 * Float(i) / Float(frames)) * 0.5 }
        switch (commonFormat, interleaved) {
        case (.pcmFormatFloat32, false):
            for c in 0..<2 { for i in 0..<Int(frames) { buf.floatChannelData![c][i] = s(i) } }
        case (.pcmFormatFloat32, true):
            let p = buf.floatChannelData![0]
            for i in 0..<Int(frames) { p[i * 2] = s(i); p[i * 2 + 1] = s(i) }
        case (.pcmFormatInt16, false):
            for c in 0..<2 { for i in 0..<Int(frames) { buf.int16ChannelData![c][i] = Int16(s(i) * 32000) } }
        case (.pcmFormatInt16, true):
            let p = buf.int16ChannelData![0]
            for i in 0..<Int(frames) { p[i * 2] = Int16(s(i) * 32000); p[i * 2 + 1] = Int16(s(i) * 32000) }
        default: XCTFail("unsupported combination")
        }
        return buf
    }

    /// Every stereo shape a capture device might hand us must survive the downmix. The
    /// Float32-deinterleaved case is THE regression guard: it is exactly what a Yeti X / Brio 505
    /// delivers, and it used to convert to silence.
    func testAllStereoLayoutsDownmixToAudibleMono() throws {
        let out = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000,
                                              channels: 1, interleaved: false))
        for (fmt, inter, label) in [(AVAudioCommonFormat.pcmFormatFloat32, false, "Float32 deinterleaved"),
                                    (.pcmFormatFloat32, true, "Float32 interleaved"),
                                    (.pcmFormatInt16, false, "Int16 deinterleaved"),
                                    (.pcmFormatInt16, true, "Int16 interleaved")] {
            let input = try stereoBuffer(commonFormat: fmt, interleaved: inter)
            XCTAssertGreaterThan(PCMConverter.rms(input), 0.1, "\(label): fixture must contain real signal")
            let converted = try XCTUnwrap(PCMConverter(outputFormat: out).convert(input), "\(label): nil")
            XCTAssertGreaterThan(PCMConverter.rms(converted), 0.1, "\(label) downmixed to silence")
        }
    }
}
