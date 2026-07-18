import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import Speech
import os

/// Receives capture sample buffers on the capture queue, converts them to the analyzer's format,
/// yields them, and meters the level. `@unchecked Sendable`: touched only on the single serial
/// capture queue after `start`.
///
/// **Why AVCaptureSession, not AVAudioEngine:** on macOS 26 / Swift 6, `AVAudioEngine.prepare()` and
/// `.start()` corrupt the Swift *main-actor executor identity* process-wide, after which every
/// `MainActor.assumeIsolated` — ours and, fatally, SwiftUI's internal gesture/body isolation
/// assertions — traps (`swift_task_isCurrentExecutor` → EXC_BAD_ACCESS). `AVCaptureSession` does the
/// same audio IO without that side effect, so the UI keeps working while recording. (Verified by
/// bisection.)
private final class CaptureSink: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let converter: PCMConverter
    private let yield: @Sendable (AnalyzerInput) -> Void
    private let levelBox: OSAllocatedUnfairLock<Float>

    init(outputFormat: AVAudioFormat, levelBox: OSAllocatedUnfairLock<Float>,
         yield: @escaping @Sendable (AnalyzerInput) -> Void) {
        self.converter = PCMConverter(outputFormat: outputFormat)
        self.levelBox = levelBox
        self.yield = yield
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer), let out = converter.convert(pcm) else { return }
        levelBox.withLock { $0 = PCMConverter.rms(out) }
        yield(AnalyzerInput(buffer: out))
    }

    /// CMSampleBuffer → AVAudioPCMBuffer in the sample buffer's own format.
    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb) else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: fd)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sb, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}

/// Microphone capture via `AVCaptureSession` (§8.3). On `start` it adds the chosen input + an audio
/// data output whose delegate converts buffers to the analyzer format and feeds an
/// `AsyncStream<AnalyzerInput>` (ORA-CAP-001, ORA-CC-002). Confirmed text lives in the coordinator,
/// so a device change never loses it (ORA-SM-002 / ORA-CAP-003).
@MainActor
public final class AudioCapture {
    public enum CaptureError: Error, Sendable { case sessionStartFailed(String), noInputDevice }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "com.grgmrr.orator.capture")
    private var sink: CaptureSink?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var runtimeErrorObserver: NSObjectProtocol?
    private var running = false

    /// Latest audio level (0…1), written on the capture queue and polled by the coordinator's UI tick.
    private let levelBox = OSAllocatedUnfairLock<Float>(initialState: 0)
    public var currentLevel: Float { levelBox.withLock { $0 } }
    /// Called if capture cannot continue after a device change, so the coordinator aborts cleanly
    /// rather than leave a dead-mic recording (ORA-REL-001).
    public var onUnrecoverableFailure: (@Sendable (String) -> Void)?

    public init() {}

    /// Begin capture, yielding into a fresh stream. `outputFormat` is the analyzer's input format.
    /// Returns only after the session has been configured; a throw means stay idle (ORA-SM-004).
    public func start(outputFormat: AVAudioFormat) throws -> AsyncStream<AnalyzerInput> {
        guard !running else { throw CaptureError.sessionStartFailed("already running") }
        guard let device = chosenDevice() else { throw CaptureError.noInputDevice }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw CaptureError.sessionStartFailed(error.localizedDescription) }

        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        guard session.canAddInput(input) else {
            session.commitConfiguration(); throw CaptureError.sessionStartFailed("cannot add input")
        }
        session.addInput(input)
        if !session.outputs.contains(output) {
            guard session.canAddOutput(output) else {
                session.commitConfiguration(); throw CaptureError.sessionStartFailed("cannot add output")
            }
            session.addOutput(output)
        }
        session.commitConfiguration()

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        let sink = CaptureSink(outputFormat: outputFormat, levelBox: levelBox, yield: { cont.yield($0) })
        self.sink = sink
        output.setSampleBufferDelegate(sink, queue: captureQueue)

        // startRunning blocks briefly; run it off-main (also keeps main clean by construction).
        nonisolated(unsafe) let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { captureSession.startRunning() }
        running = true
        observeRuntimeErrors()
        return stream
    }

    /// Tear down capture. Idempotent. Finishes the stream so the engine's consumer task ends.
    public func stop() {
        guard running else { return }
        running = false
        if let obs = runtimeErrorObserver { NotificationCenter.default.removeObserver(obs); runtimeErrorObserver = nil }
        output.setSampleBufferDelegate(nil, queue: nil)
        nonisolated(unsafe) let captureSession = session
        DispatchQueue.global(qos: .userInitiated).async { captureSession.stopRunning() }
        continuation?.finish()
        continuation = nil
        sink = nil
    }

    // MARK: Device selection (ORA-CAP-002)

    private func chosenDevice() -> AVCaptureDevice? {
        switch Settings.shared.micPolicy {
        case .followDefault:
            // Respects the user's chosen input, including in clamshell mode (ORA-CAP-002).
            return AVCaptureDevice.default(for: .audio)
        case .builtIn:
            return Self.builtInMicrophone()
        }
    }

    /// Resolve the built-in microphone (internal + static so the headless test can verify it never
    /// falls through to a flaky Continuity/Bluetooth device).
    static func builtInMicrophone() -> AVCaptureDevice? {
        let mics = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external],
                                                    mediaType: .audio, position: .unspecified).devices
        // Authoritative: match the CoreAudio device whose transport type is Built-in (see CoreAudioSupport).
        // The built-in is *named* for the model ("MacBook Air Microphone"), not "built-in", so a name match
        // is unreliable.
        if let uid = CoreAudioSupport.builtInInputUID(),
           let match = mics.first(where: { $0.uniqueID == uid }) {
            return match
        }
        // Fallbacks: name hints for Apple built-in mics, then the system default, then anything.
        let hints = ["built-in", "macbook", "imac", "mac mini", "mac studio", "mac pro"]
        if let named = mics.first(where: { d in
            let n = d.localizedName.lowercased(); return hints.contains { n.contains($0) }
        }) { return named }
        return AVCaptureDevice.default(for: .audio) ?? mics.first
    }

    // MARK: Device-change survival (ORA-CAP-003 / E6)

    private func observeRuntimeErrors() {
        runtimeErrorObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main
        ) { [weak self] note in
            // Extract the (Sendable) message before hopping onto the main actor.
            let err = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "audio error"
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                Log.audio.error("Capture session runtime error: \(err)")
                // AVCaptureSession recovers from most device changes on its own; if it truly stopped,
                // surface it so confirmed text is preserved (ORA-REL-002).
                if !self.session.isRunning {
                    self.onUnrecoverableFailure?("Lost the microphone. Your text so far was saved to recovery.")
                }
            }
        }
    }
}
