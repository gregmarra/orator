import XCTest
@preconcurrency import AVFoundation
import CoreMedia
import Speech
@testable import OratorKit

/// A/B accuracy harness for the capture→analyzer conversion path.
///
/// **Method.** Record the phrase set ONCE through the real microphone, in lossless Float32 *stereo* at
/// the device's native rate, and keep it. Then replay that identical recording through each candidate
/// conversion configuration and score the transcripts against ground truth. Because every
/// configuration sees the same audio, differences are attributable to the conversion and not to room
/// noise, mic position, or how a sentence happened to be spoken.
///
/// The recording is acoustic (speaker → microphone), so results are specific to the machine and mic
/// placement they were captured on — re-record after moving the mic.
///
/// Opt-in: it plays audio aloud and takes minutes.
///     ORATOR_ACCURACY=1 swift test --filter AccuracyHarnessTests
final class AccuracyHarnessTests: XCTestCase {

    /// Phonetically varied, plus the failure modes that actually matter for dictation: digits,
    /// homophones, proper nouns, technical terms, and long clauses where an early error cascades.
    private static let phrases = [
        "the quick brown fox jumps over the lazy dog",
        "she sells seashells by the seashore on a sunny afternoon",
        "please schedule the meeting for four thirty on Tuesday the twenty third",
        "the invoice total came to nine hundred and forty two dollars",
        "we should refactor the session coordinator before shipping the release",
        "their there and they're are homophones that trip up dictation",
        "send the draft to Priya and Michael before the end of the day",
        "the microphone captures audio at forty eight kilohertz in stereo",
        "I think we need to double check the accuracy of these numbers",
        "remind me to buy milk eggs bread and coffee on the way home",
    ]

    /// Fixed path (not the per-process temp dir) so recordings can be inspected and re-scored.
    private var recordingsDir: URL {
        URL(fileURLWithPath: "/tmp/orator-accuracy")
    }

    // MARK: Configurations under test

    private struct Config {
        let name: String
        let quality: Int
        /// nil = let AVAudioConverter downmix (averages the channels); [0] = take one capsule only.
        let channelMap: [NSNumber]?
    }

    private static let configs = [
        Config(name: "capsule 0, min quality", quality: AVAudioQuality.min.rawValue, channelMap: [0]),
        Config(name: "capsule 0, medium (default)", quality: AVAudioQuality.medium.rawValue, channelMap: [0]),
        Config(name: "capsule 0, MAX quality", quality: AVAudioQuality.max.rawValue, channelMap: [0]),
        Config(name: "capsule 1, MAX quality", quality: AVAudioQuality.max.rawValue, channelMap: [1]),
    ]

    // MARK: Record

    /// Capture the phrase set through the real mic in lossless stereo Float32.
    @MainActor
    private func recordPhrases(device: AVCaptureDevice) async throws -> [(phrase: String, url: URL)] {
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        var out: [(String, URL)] = []
        let reuse = ProcessInfo.processInfo.environment["ORATOR_REUSE"] != nil
        if reuse {
            let urls = Self.phrases.indices.map { recordingsDir.appendingPathComponent("phrase-\($0).caf") }
            if urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                print("  reusing \(urls.count) existing recordings")
                return Array(zip(Self.phrases, urls))
            }
        }
        for (i, phrase) in Self.phrases.enumerated() {
            let url = recordingsDir.appendingPathComponent("phrase-\(i).caf")
            try? FileManager.default.removeItem(at: url)

            let session = AVCaptureSession()
            let output = AVCaptureAudioDataOutput()
            // Lossless relative to the device's 24-bit native format, and keeps BOTH channels so the
            // downmix strategy is still a free variable at scoring time.
            output.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
            ]
            let writer = FileWriter(url: url)
            output.setSampleBufferDelegate(writer, queue: DispatchQueue(label: "rec"))
            session.beginConfiguration()
            session.addInput(try AVCaptureDeviceInput(device: device))
            session.addOutput(output)
            session.commitConfiguration()
            session.startRunning()
            try await Task.sleep(for: .milliseconds(300))       // let capture settle

            let say = Process()
            say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
            say.arguments = ["-r", "175", phrase]
            try say.run()
            say.waitUntilExit()
            try await Task.sleep(for: .milliseconds(500))       // capture the tail

            session.stopRunning()
            output.setSampleBufferDelegate(nil, queue: nil)
            writer.close()
            print("  recorded [\(i + 1)/\(Self.phrases.count)] peak=\(String(format: "%.3f", writer.peak))")
            out.append((phrase, url))
        }
        return out
    }

    // MARK: Score

    /// Word error rate (Levenshtein over words), the standard transcription accuracy measure.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double {
        func norm(_ s: String) -> [String] {
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        }
        let r = norm(reference), h = norm(hypothesis)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        // An empty hypothesis is a total miss — and `1...h.count` would trap on it.
        guard !h.isEmpty else { return 1 }
        var prev = Array(0...h.count)
        var cur = [Int](repeating: 0, count: h.count + 1)
        for i in 1...r.count {
            cur[0] = i
            for j in 1...h.count {
                cur[j] = r[i - 1] == h[j - 1] ? prev[j - 1]
                                              : 1 + min(prev[j - 1], min(prev[j], cur[j - 1]))
            }
            swap(&prev, &cur)
        }
        return Double(prev[h.count]) / Double(r.count)
    }

    @MainActor
    private func transcribe(_ url: URL, config: Config, engine: SpeechEngine,
                            target: AVAudioFormat) async throws -> String {
        let collector = TranscriptCollector()
        engine.sink = collector
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) }
        catch { XCTFail("open \(url.lastPathComponent): \(String(reflecting: error))"); return "" }
        let inFmt = file.processingFormat
        guard let conv = AVAudioConverter(from: inFmt, to: target) else {
            XCTFail("no converter from \(inFmt) to \(target)"); return ""
        }
        guard let token = await engine.beginSession() else {
            XCTFail("beginSession returned nil while scoring"); return ""
        }
        conv.sampleRateConverterQuality = config.quality
        if let map = config.channelMap { conv.channelMap = map }

        // Drive by file length: `AVAudioFile.read` throws `_GenericObjCError.nilError` at EOF rather
        // than returning zero frames, so a read-until-empty loop always ends in a spurious error.
        let chunk: AVAudioFrameCount = 4800
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: min(chunk, remaining)) else { break }
            do { try file.read(into: buf, frameCount: min(chunk, remaining)) }
            catch { XCTFail("read: \(String(reflecting: error))"); break }
            if buf.frameLength == 0 { break }
            let cap = AVAudioFrameCount(Double(buf.frameLength) * (target.sampleRate / inFmt.sampleRate)) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { break }
            let once = ConsumeOnce()
            let st = conv.convert(to: out, error: nil) { _, s in
                if once.done { s.pointee = .noDataNow; return nil }
                once.done = true; s.pointee = .haveData; return buf
            }
            if st != .error, out.frameLength > 0 { engine.feed(AnalyzerInput(buffer: out), for: token) }
            // Pace at wall-clock, like a microphone. Fed flat out the analyzer returns NOTHING —
            // the same trap that made an earlier engine test pass for the wrong reason.
            let ms = Int(Double(buf.frameLength) / inFmt.sampleRate * 1000)
            try? await Task.sleep(for: .milliseconds(ms))
        }
        _ = await engine.finalize(within: .seconds(10))
        try? await Task.sleep(for: .milliseconds(500))
        engine.endSession()
        return collector.confirmed
    }

    // MARK: The run

    @MainActor
    func testCompareConversionConfigurations() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ORATOR_ACCURACY"] != nil,
                          "set ORATOR_ACCURACY=1 to run the accuracy harness (plays audio, takes minutes)")
        let engine = SpeechEngine(locale: Locale(identifier: "en-US"))
        let status = await engine.modelStatus()
        try XCTSkipUnless(status == .installed, "en-US model not installed")
        try await engine.warmUp()
        let target = try XCTUnwrap(engine.inputFormat)

        let device = try XCTUnwrap(AudioCapture.resolveChoice().device, "no usable input device")
        print("\n=== RECORDING through \(device.localizedName) ===")
        let recordings = try await recordPhrases(device: device)

        print("\n=== SCORING (\(Self.configs.count) configurations × \(recordings.count) phrases) ===")
        var results: [(String, Double)] = []
        for config in Self.configs {
            var total = 0.0
            for (phrase, url) in recordings {
                let text: String
                do { text = try await transcribe(url, config: config, engine: engine, target: target) }
                catch { XCTFail("transcribe(\(url.lastPathComponent)) threw: \(error)"); return }
                let wer = Self.wordErrorRate(reference: phrase, hypothesis: text)
                total += wer
                if wer > 0 { print("   [\(config.name)] WER \(String(format: "%.2f", wer)): '\(text)'") }
            }
            let mean = total / Double(recordings.count)
            results.append((config.name, mean))
            print(">>> \(config.name): mean WER = \(String(format: "%.4f", mean))")
        }

        print("\n=== RESULTS (lower is better) ===")
        for (name, wer) in results.sorted(by: { $0.1 < $1.1 }) {
            print(String(format: "   %.4f  %@", wer, name))
        }
    }
}

/// One-shot flag for the converter's input block. A reference box rather than a captured `var`: the
/// block is `@Sendable`, so mutating a local from inside it is a data-race warning in Swift 6. Mirrors
/// the box `PCMConverter` uses on the real path.
private final class ConsumeOnce: @unchecked Sendable { var done = false }

/// Writes captured buffers to a file in their delivered format, tracking peak for a clipping check.
private final class FileWriter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let url: URL
    private var file: AVAudioFile?
    private(set) var peak: Float = 0
    init(url: URL) { self.url = url }

    func captureOutput(_ o: AVCaptureOutput, didOutput sb: CMSampleBuffer, from c: AVCaptureConnection) {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return }
        let fmt = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return }
        pcm.frameLength = frames
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                           into: pcm.mutableAudioBufferList) == noErr else { return }
        peak = max(peak, PCMConverter.peak(pcm))
        if file == nil {
            file = try? AVAudioFile(forWriting: url, settings: fmt.settings,
                                    commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
        }
        try? file?.write(from: pcm)
    }

    func close() { file = nil }
}
