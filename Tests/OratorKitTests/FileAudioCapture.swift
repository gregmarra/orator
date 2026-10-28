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
    let holdsOpen: Bool
    let stopped: OSAllocatedUnfairLock<Bool>
    let yield: @Sendable (AnalyzerInput) -> Void
    let finish: @Sendable () -> Void

    /// Realtime mode paces 100 ms chunks of the file's OWN sample rate on an absolute schedule — a
    /// fixed 4800-frame chunk ran `say`'s 22.05 kHz output at ~2.2× speed. `holdsOpen` then keeps
    /// delivering silence until `stop`, as a microphone does; ending the stream at EOF instead left
    /// the analyzer seconds of nothing before the stop, flattering every stop-path timing.
    func run() {
        let format = file.processingFormat
        let chunkFrames = AVAudioFrameCount(format.sampleRate * 0.1)
        let chunkSeconds = Double(chunkFrames) / format.sampleRate
        let began = Date()
        var chunks = 0.0
        var reachedEOF = false
        while !stopped.withLock({ $0 }) {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { break }
            // `read(into:)` throws at EOF rather than returning zero frames, so check the position.
            if !reachedEOF, file.framePosition < file.length {
                do { try file.read(into: buf) } catch { break }
            } else {
                reachedEOF = true
            }
            if reachedEOF {
                guard holdsOpen else { break }              // the stream ends at EOF
                buf.frameLength = chunkFrames               // silence (processingFormat is Float32)
                for ch in 0..<Int(format.channelCount) {
                    buf.floatChannelData?[ch].update(repeating: 0, count: Int(chunkFrames))
                }
            }
            if let out = converter.convert(buf) {
                levelBox.withLock { $0 = PCMConverter.rms(out) }
                yield(AnalyzerInput(buffer: out))
            }
            if realtime {
                chunks += 1
                let wait = began.addingTimeInterval(chunks * chunkSeconds).timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
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
    private let holdsOpen: Bool
    private let levelBox = OSAllocatedUnfairLock<Float>(initialState: 0)
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private let feederQueue = DispatchQueue(label: "com.grgmrr.orator.filecapture")
    private var startedAt: ContinuousClock.Instant?
    private var stopped = OSAllocatedUnfairLock(initialState: false)

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
    /// - Parameter holdsOpen: after the file ends, keep delivering silence until `stop` (realtime
    ///   only) instead of ending the stream — what a coordinator, which stops on a hotkey, sees.
    public init(url: URL, realtime: Bool = false, holdsOpen: Bool = false) {
        self.url = url
        self.realtime = realtime
        self.holdsOpen = realtime && holdsOpen
    }

    public func start(outputFormat: AVAudioFormat,
                      excluding: Set<String> = []) throws -> AsyncStream<AnalyzerInput> {
        let file = try AVAudioFile(forReading: url)
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        stopped = OSAllocatedUnfairLock(initialState: false)   // per run: a late feeder can't see the next
        let feeder = FileFeeder(file: file, converter: PCMConverter(outputFormat: outputFormat),
                                levelBox: levelBox, realtime: realtime, holdsOpen: holdsOpen, stopped: stopped,
                                yield: { cont.yield($0) }, finish: { cont.finish() })
        startedAt = ContinuousClock.now
        feederQueue.async { feeder.run() }
        return stream
    }

    public func stop() {
        stopped.withLock { $0 = true }
        continuation?.finish()
        continuation = nil
        startedAt = nil
    }
}
