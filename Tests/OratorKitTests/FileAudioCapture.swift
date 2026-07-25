import Foundation
@preconcurrency import AVFoundation
import Speech
import os
@testable import OratorKit

/// Reads + converts a file off the main actor, mirroring the mic's capture queue. `@unchecked
/// Sendable`: its non-Sendable state (the file + converter) is touched only on the one feeder queue.
private struct FileFeeder: @unchecked Sendable {
    let file: AVAudioFile
    let converter: PCMConverter
    let levelBox: OSAllocatedUnfairLock<Float>
    let realtime: Bool
    let yield: @Sendable (AnalyzerInput) -> Void
    let finish: @Sendable () -> Void

    func run() {
        let format = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 4800   // ~100 ms at 48 kHz
        while true {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            do { try file.read(into: buf) } catch { break }
            if buf.frameLength == 0 { break }   // EOF
            if let out = converter.convert(buf) {
                levelBox.withLock { $0 = PCMConverter.rms(out) }
                yield(AnalyzerInput(buffer: out))
            }
            if realtime { Thread.sleep(forTimeInterval: 0.1) }
        }
        finish()
    }
}

/// An audio source that replays an audio file instead of a live mic, converting through
/// the *same* `PCMConverter` the mic path uses. The seam that makes dictation verifiable end-to-end
/// with no mic and no user: feed a known utterance, drive the real `SpeechAnalyzer`, assert on the
/// transcript (see the headless E2E test).
@MainActor
public final class FileAudioCapture: AudioSource {
    private let url: URL
    private let realtime: Bool
    private let levelBox = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let feederQueue = DispatchQueue(label: "com.grgmrr.orator.filecapture")
    private var startedAt: ContinuousClock.Instant?

    public var currentLevel: Float { levelBox.withLock { $0 } }
    public var onUnrecoverableFailure: (@Sendable (String) -> Void)?
    /// The file feeder never stalls, so this only has to keep the watchdog quiet while running.
    public var secondsSinceLastBuffer: TimeInterval? {
        guard startedAt != nil else { return nil }
        return 0
    }
    public var hasDeliveredAudio: Bool { startedAt != nil }
    /// Replaying a file is not a device; there is nothing to exclude on failover.
    public var currentDeviceUID: String? { nil }

    /// - Parameter realtime: when true, pace chunks at ~wall-clock speed (mimicking a mic); when
    ///   false, feed as fast as possible (fastest for tests).
    public init(url: URL, realtime: Bool = false) {
        self.url = url
        self.realtime = realtime
    }

    public func start(outputFormat: AVAudioFormat,
                      excluding: Set<String> = []) throws -> AsyncStream<AnalyzerInput> {
        let file = try AVAudioFile(forReading: url)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        let feeder = FileFeeder(file: file, converter: PCMConverter(outputFormat: outputFormat),
                                levelBox: levelBox, realtime: realtime,
                                yield: { cont.yield($0) }, finish: { cont.finish() })
        startedAt = ContinuousClock.now
        feederQueue.async { feeder.run() }
        return stream
    }

    public func stop() {
        continuation?.finish()
        continuation = nil
        startedAt = nil
    }
}
