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
    /// Metering-only (Settings level bar): compute RMS from the raw capture buffer and skip the
    /// analyzer-format conversion + yield entirely — nothing downstream consumes the stream, so the
    /// per-buffer convert + allocation would be pure waste.
    private let meteringOnly: Bool

    init(outputFormat: AVAudioFormat, levelBox: OSAllocatedUnfairLock<Float>, meteringOnly: Bool = false,
         yield: @escaping @Sendable (AnalyzerInput) -> Void) {
        self.converter = PCMConverter(outputFormat: outputFormat)
        self.levelBox = levelBox
        self.meteringOnly = meteringOnly
        self.yield = yield
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        if meteringOnly {
            levelBox.withLock { $0 = PCMConverter.rms(pcm) }   // RMS is format-agnostic; no conversion needed
            return
        }
        guard let out = converter.convert(pcm) else { return }
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
    public enum CaptureError: Error, Sendable, LocalizedError {
        case sessionStartFailed(String), noInputDevice
        /// User-facing copy — kept in sync with the meter readout so the two failure surfaces can't
        /// drift (ORA-CAP-015). The associated string carries the raw reason for logs only.
        public var errorDescription: String? {
            switch self {
            case .noInputDevice:      return "No microphone is connected."
            case .sessionStartFailed: return "The microphone couldn’t be opened — it may be in use."
            }
        }
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let captureQueue = DispatchQueue(label: "com.grgmrr.orator.capture")
    /// Serializes ALL session mutation — configuration + startRunning/stopRunning — so a stop can
    /// never overlap or reorder against a following start (ORA-CAP-004). Without this, both were
    /// dispatched to the concurrent global queue and a rapid stop→start (e.g. the Settings meter's
    /// restart) could leave the session running after stop (mic never released) or stopped after
    /// start (dead capture).
    private let sessionQueue = DispatchQueue(label: "com.grgmrr.orator.session")
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

    /// Begin capture, yielding into a fresh stream. `outputFormat` is the analyzer's input format;
    /// `meteringOnly` runs the level meter without converting/yielding (Settings preview).
    /// Returns only after the session has been configured; a throw means stay idle (ORA-SM-004).
    public func start(outputFormat: AVAudioFormat, meteringOnly: Bool = false) throws -> AsyncStream<AnalyzerInput> {
        guard !running else { throw CaptureError.sessionStartFailed("already running") }
        guard let device = chosenDevice() else { throw CaptureError.noInputDevice }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw CaptureError.sessionStartFailed(error.localizedDescription) }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        let sink = CaptureSink(outputFormat: outputFormat, levelBox: levelBox,
                               meteringOnly: meteringOnly, yield: { cont.yield($0) })
        self.sink = sink
        output.setSampleBufferDelegate(sink, queue: captureQueue)

        // ALL session mutation (config + startRunning) runs on the serial sessionQueue, ordered AFTER
        // any pending stop()'s stopRunning — but *asynchronously*, so the MainActor never blocks
        // waiting on stopRunning (ORA-CAP-004/013). The one throwable step that must gate `.recording`
        // — opening the device — already happened above via AVCaptureDeviceInput(device:); canAdd
        // failures here are effectively impossible for audio and are logged, not thrown.
        nonisolated(unsafe) let captureSession = session
        nonisolated(unsafe) let captureOutput = output
        nonisolated(unsafe) let addedInput = input
        sessionQueue.async {
            captureSession.beginConfiguration()
            captureSession.inputs.forEach { captureSession.removeInput($0) }
            if captureSession.canAddInput(addedInput) { captureSession.addInput(addedInput) }
            else { Log.audio.error("Cannot add microphone input") }
            if !captureSession.outputs.contains(captureOutput) {
                if captureSession.canAddOutput(captureOutput) { captureSession.addOutput(captureOutput) }
                else { Log.audio.error("Cannot add audio output") }
            }
            captureSession.commitConfiguration()
            captureSession.startRunning()
        }
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
        sessionQueue.async { captureSession.stopRunning() }   // serialized with config/start (ORA-CAP-004)
        continuation?.finish()
        continuation = nil
        sink = nil
    }

    // MARK: Device selection (ORA-CAP-002)

    /// The outcome of resolving `MicSelection` to a device, plus whether it's a substitute — so the
    /// Settings readout can show the effective mode instead of silently implying the picked one
    /// (ORA-CAP-005).
    struct MicChoice: Sendable {
        let device: AVCaptureDevice?
        /// True when the resolved device is a *substitute* for the selection (pinned mic absent, garbage
        /// default, or no built-in); false when the selection was used as-is. The user-facing wording is
        /// the presentation layer's job (see `SettingsView.micStatusText`).
        let substituted: Bool
    }

    /// Injectable view of the device world, so the pure selection decision (`resolveUID`) is unit
    /// testable with a fake instead of real hardware (ORA-CAP-012). `.live` reads Core Audio +
    /// AVFoundation. `isUsable` means "channel-bearing AND vendable as an AVCaptureDevice" — so
    /// aggregate/virtual devices we can't actually open are excluded from selection (ORA-CAP-016).
    struct DeviceProvider {
        var defaultInputUID: @MainActor () -> String?
        var builtInUID: @MainActor () -> String?
        var isUsable: @MainActor (String) -> Bool
        var orderedInputUIDs: @MainActor () -> [String]

        static var live: DeviceProvider {
            DeviceProvider(
                defaultInputUID: { CoreAudioSupport.defaultInputUID() },
                builtInUID: { AudioCapture.cachedBuiltInInputUID() },
                isUsable: { AudioCapture.isVendableInput(uid: $0) },
                orderedInputUIDs: { CoreAudioSupport.inputDeviceList().map(\.uid) })
        }
    }

    /// The single definition of "an input device we can actually capture from": it has input channels
    /// (Core Audio) AND is vendable as an `AVCaptureDevice` (excludes aggregates/virtual drivers that
    /// pass the channel filter but can't be opened). Used by both selection (`DeviceProvider.live`) and
    /// the Settings picker filter, so the two can't disagree (ORA-CAP-016).
    static func isVendableInput(uid: String) -> Bool {
        CoreAudioSupport.isUsableInput(uid: uid) && AVCaptureDevice(uniqueID: uid) != nil
    }

    private func chosenDevice() -> AVCaptureDevice? { Self.resolveChoice().device }

    /// Resolve the current `MicSelection` to a device + substitution reason. O(1) Core Audio IPC on the
    /// common (as-selected) path — the hotkey→capture-start hot path — enumerating only on the cold
    /// garbage-default/absent-pin fallback (see `resolveUID`).
    static func resolveChoice() -> MicChoice {
        let (uid, substituted) = resolveUID(Settings.shared.micSelection, using: .live)
        guard let uid, let dev = AVCaptureDevice(uniqueID: uid) else {
            return MicChoice(device: nil, substituted: substituted)
        }
        return MicChoice(device: dev, substituted: substituted)
    }

    static func resolveDevice() -> AVCaptureDevice? { resolveChoice().device }

    /// PURE selection decision over an injected `DeviceProvider` — no hardware, no AVCaptureDevice
    /// materialization — so every fallback/substitution branch is headlessly testable (ORA-CAP-012).
    /// `substituted` is true when the returned UID isn't the one the selection asked for. Returns nil
    /// `uid` only when NOTHING is usable, so the caller throws `noInputDevice` instead of silently
    /// capturing a dead device (ORA-CAP-006).
    static func resolveUID(_ selection: MicSelection, using p: DeviceProvider) -> (uid: String?, substituted: Bool) {
        switch selection {
        case .automatic:
            let (uid, fellBack) = automaticUID(using: p)   // fellBack IS the substitution
            return (uid, fellBack)
        case .builtIn:
            if let uid = p.builtInUID(), p.isUsable(uid) { return (uid, false) }
            return (bestUsableUID(using: p), true)   // no built-in → substitute (nil if nothing usable)
        case .device(let pinned):
            // Sticky pin: use it when present AND usable; when replugged it satisfies this again, so
            // the preference re-engages with no relatch.
            if p.isUsable(pinned) { return (pinned, false) }
            // Absent/unusable pin → system default (itself possibly a further substitute).
            return (automaticUID(using: p).uid, true)
        }
    }

    /// System default if usable, else the best usable input. `fellBack` is true when the default was
    /// unusable and we substituted.
    private static func automaticUID(using p: DeviceProvider) -> (uid: String?, fellBack: Bool) {
        if let uid = p.defaultInputUID(), p.isUsable(uid) { return (uid, false) }
        return (bestUsableUID(using: p), true)
    }

    /// Best usable input UID: prefer the built-in, else the first usable present device. Consults
    /// `orderedInputUIDs` (enumeration) — only reached on the cold fallback path, never the hot path.
    private static func bestUsableUID(using p: DeviceProvider) -> String? {
        if let uid = p.builtInUID(), p.isUsable(uid) { return uid }
        return p.orderedInputUIDs().first(where: p.isUsable)
    }

    /// Materialized best-usable input: the terminal fallback the resolver would land on, as a real
    /// device. Nil when nothing is usable. (Also the seam the headless usability test asserts against.)
    static func bestUsableInput() -> AVCaptureDevice? {
        guard let uid = bestUsableUID(using: .live) else { return nil }
        return AVCaptureDevice(uniqueID: uid)
    }

    /// The built-in input UID, memoized — INCLUDING the negative result, so a Mac with no built-in
    /// transport doesn't re-enumerate on every record start (ORA-CAP-007). A cached *positive* self-
    /// heals via the O(1) `isUsableInput` check; the cache is dropped on a Core Audio device change
    /// (`invalidateBuiltInCache`, called by AudioDeviceList) so a stale UID can't stick.
    private enum BuiltInCache { case unknown, resolved(String?) }
    private static var builtInCache: BuiltInCache = .unknown
    static func cachedBuiltInInputUID() -> String? {
        installBuiltInInvalidationListenerIfNeeded()
        if case .resolved(let cached) = builtInCache {
            if let cached {
                if CoreAudioSupport.isUsableInput(uid: cached) { return cached }   // still present → O(1)
                // was present, now gone → re-resolve below
            } else {
                return nil   // negative memo: no built-in — don't re-enumerate every call
            }
        }
        let uid = CoreAudioSupport.builtInInputUID()
        builtInCache = .resolved(uid)
        return uid
    }
    /// Drop the memoized built-in UID (call on a Core Audio device topology change).
    static func invalidateBuiltInCache() { builtInCache = .unknown }

    /// A single PROCESS-lifetime device-change listener that invalidates the built-in cache, so the
    /// NEGATIVE memo re-probes when a built-in mic reappears (clamshell/undock/replug) even with
    /// Settings closed (ORA-CAP-024). AudioDeviceList's own invalidation only runs while Settings is
    /// open, which would otherwise leave `.builtIn` mode stuck at "no built-in" indefinitely.
    private static var invalidationListenerInstalled = false
    private static func installBuiltInInvalidationListenerIfNeeded() {
        guard !invalidationListenerInstalled else { return }
        invalidationListenerInstalled = true
        let (_, status) = CoreAudioSupport.addSystemListener(kAudioHardwarePropertyDevices) { _, _ in
            MainActor.assumeIsolated { AudioCapture.invalidateBuiltInCache() }
        }
        if status != noErr { Log.audio.error("Built-in cache listener registration failed: \(status)") }
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
                // surface it so confirmed text is preserved (ORA-REL-002). Read `isRunning` on the
                // session's own serial queue — never off-queue on this non-thread-safe object
                // (ORA-CAP-014) — then hop back to main to report.
                nonisolated(unsafe) let s = self.session
                self.sessionQueue.async { [weak self] in
                    let stopped = !s.isRunning
                    guard stopped else { return }
                    // Re-check `running` back on the actor: a normal stop() (or a stop already in
                    // flight) also leaves the session not-running, and must NOT be reported as an
                    // unrecoverable failure — only a genuine loss during an active session (ORA-CAP-022).
                    Task { @MainActor in
                        guard let self, self.running else { return }
                        self.onUnrecoverableFailure?("Lost the microphone. Your text so far was saved to recovery.")
                    }
                }
            }
        }
    }
}
