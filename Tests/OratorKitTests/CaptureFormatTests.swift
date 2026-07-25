import XCTest
@preconcurrency import AVFoundation
@testable import OratorKit

final class CaptureFormatTests: XCTestCase {

    /// Deterministic guard for the stereo-USB-mic silence bug. Capture MUST request mono: left to the
    /// device's native format, a stereo mic delivers 2-channel 24-bit packed LPCM, whose downmix
    /// `AVAudioConverter` performs as silence and whose samples `PCMConverter.rms` cannot read at all.
    /// Both failures are silent, so nothing downstream can detect them — this is the only place the
    /// requirement can be pinned without hardware.
    @MainActor
    func testCaptureRequestsMonoFloat32() throws {
        let s = AudioCapture.monoFloatSettings
        XCTAssertEqual(s[AVNumberOfChannelsKey] as? Int, 1,
                       "capture must request MONO — stereo downmix in AVAudioConverter yields silence")
        XCTAssertEqual(s[AVFormatIDKey] as? UInt32, kAudioFormatLinearPCM)
        XCTAssertEqual(s[AVLinearPCMIsFloatKey] as? Bool, true,
                       "Float32 keeps buffers readable by PCMConverter.rms (24-bit packed is not)")
        XCTAssertEqual(s[AVLinearPCMBitDepthKey] as? Int, 32)
    }
}
