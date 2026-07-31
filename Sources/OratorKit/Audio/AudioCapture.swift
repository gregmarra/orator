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
    /// Nil in metering mode (Settings level bar): compute RMS from the raw capture buffer and skip the
    /// analyzer-format conversion + yield entirely — nothing downstream consumes the stream, so the
    /// per-buffer convert + allocation would be pure waste. "No output format" and "metering" are the
    /// same fact, so this stands in for the separate flag they used to be.
    private let converter: PCMConverter?
    private let yield: @Sendable (AnalyzerInput) -> Void
    private let levelBox: OSAllocatedUnfairLock<Float>
    /// Instant of the most recent delivered buffer, for the coordinator's capture watchdog. Stamped
    /// before any conversion so a converter failure still counts as "audio is arriving".
    private let lastBufferBox: OSAllocatedUnfairLock<ContinuousClock.Instant?>
    private let hasDeliveredBox: OSAllocatedUnfairLock<Bool>
    private let clipBox: OSAllocatedUnfairLock<ContinuousClock.Instant?>
    /// One-shot so a per-buffer failure can't flood the log.
    private var loggedConvertFailure = false
    private var loggedWrapFailure = false
    private var loggedFirstBuffer = false

    init(outputFormat: AVAudioFormat?, levelBox: OSAllocatedUnfairLock<Float>,
         lastBufferBox: OSAllocatedUnfairLock<ContinuousClock.Instant?>,
         hasDeliveredBox: OSAllocatedUnfairLock<Bool>,
         clipBox: OSAllocatedUnfairLock<ContinuousClock.Instant?>,
         yield: @escaping @Sendable (AnalyzerInput) -> Void) {
        self.converter = outputFormat.map(PCMConverter.init(outputFormat:))
        self.levelBox = levelBox
        self.lastBufferBox = lastBufferBox
        self.hasDeliveredBox = hasDeliveredBox
        self.clipBox = clipBox
        self.yield = yield
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        lastBufferBox.withLock { $0 = ContinuousClock.now }
        hasDeliveredBox.withLock { $0 = true }
        guard let pcm = Self.pcmBuffer(from: sampleBuffer) else {
            if !loggedWrapFailure {
                loggedWrapFailure = true
                Log.audio.error("Sample buffers are arriving but cannot be wrapped as PCM — no audio will reach the recognizer")
            }
            return
        }
        // Clipping is judged on the RAW buffer: it happens at the device's converter input, and the
        // RMS level the meter shows cannot reveal it (clipped and merely-loud have nearly equal RMS).
        if PCMConverter.peak(pcm) >= PCMConverter.clippingThreshold {
            clipBox.withLock { $0 = ContinuousClock.now }
        }
        // First buffer only: separates "no audio at all" from "audio arriving but silent", and records
        // the delivered format — the three facts every silent-capture report needs.
        if !loggedFirstBuffer {
            loggedFirstBuffer = true
            Log.audio.notice("First buffer: format=\(pcm.format, privacy: .public) frames=\(pcm.frameLength) rawRMS=\(PCMConverter.rms(pcm), format: .fixed(precision: 4), privacy: .public)")
        }
        guard let converter else {
            levelBox.withLock { $0 = PCMConverter.rms(pcm) }   // RMS is format-agnostic; no conversion needed
            return
        }
        guard let out = converter.convert(pcm) else {
            // A converter that fails every buffer is indistinguishable from a dead microphone at every
            // surface the user can see: no level, no waveform, no transcript. Say so, once.
            if !loggedConvertFailure {
                loggedConvertFailure = true
                Log.audio.error("Format conversion FAILED — input \(pcm.format) is not convertible to the analyzer format; no audio will reach the recognizer")
            }
            return
        }
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

    /// Instant of the most recent sample buffer, written on the capture queue.
    private let lastBufferBox = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    /// Whether ANY buffer has arrived since `start`. Separates "still waking up" from "was delivering
    /// and stopped" — Bluetooth HFP and Continuity mics routinely take 1–3 s to produce their first
    /// buffer, and a single budget covering both would kill a microphone that was about to work.
    private let hasDeliveredBox = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Seconds since capture last delivered a buffer, or nil when not running. Before the first buffer
    /// this measures from `start`, so a session that never starts at all is still caught.
    public var secondsSinceLastBuffer: TimeInterval? {
        guard running, let since = lastBufferBox.withLock({ $0 }) else { return nil }
        return (ContinuousClock.now - since).milliseconds / 1000
    }

    /// True once capture has delivered at least one buffer for the current session. The watchdog uses
    /// it to pick between the generous startup budget and the tight steady-state one.
    public var hasDeliveredAudio: Bool { hasDeliveredBox.withLock { $0 } }

    /// Instant of the most recent clipped buffer, written on the capture queue.
    private let clipBox = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
    /// True when input hit the rails recently. Clipping is measured on the RAW buffer — it happens at
    /// the converter's input, and the level meter's RMS hides it entirely (a clipped signal and a
    /// merely loud one have nearly the same RMS). Held briefly so a transient still registers on a
    /// readout the user only glances at.
    public var isClipping: Bool {
        guard let at = clipBox.withLock({ $0 }) else { return false }
        return (ContinuousClock.now - at).milliseconds / 1000 < Self.clipHoldSeconds
    }
    private static let clipHoldSeconds: TimeInterval = 1.5
    /// Called if capture cannot continue after a device change, so the coordinator aborts cleanly
    /// rather than leave a dead-mic recording (ORA-REL-001).
    public var onUnrecoverableFailure: (@Sendable (String) -> Void)?

    /// The format we require from the capture pipeline (see the rationale at the use site): mono,
    /// Float32, little-endian. Mono is the load-bearing part — it moves the stereo→mono downmix out of
    /// `AVAudioConverter`, which performs it silently and wrongly.
    static let monoFloatSettings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsBigEndianKey: false,
        AVNumberOfChannelsKey: 1,
    ]

    public init() {}

    /// Begin capture for a dictation (`AudioSource` conformance).
    public func start(outputFormat: AVAudioFormat,
                      excluding: Set<String> = []) throws -> AsyncStream<AnalyzerInput> {
        try beginCapture(outputFormat: outputFormat, excluding: excluding)
    }

    /// Begin capture for the Settings level meter: computes RMS from the raw buffer and neither
    /// converts nor yields, so the returned stream stays empty and needs no consumer. Takes no format
    /// precisely because it needs none — the caller used to invent a dummy 16 kHz one solely to satisfy
    /// this signature, and it reached nothing but a log field.
    public func startMetering() throws -> AsyncStream<AnalyzerInput> {
        try beginCapture(outputFormat: nil, excluding: [])
    }

    /// UID of the device currently open, so a failed one can be excluded from a failover retry.
    public private(set) var currentDeviceUID: String?

    /// Begin capture, yielding into a fresh stream. `outputFormat` is the analyzer's input format, or
    /// nil to run the level meter without converting/yielding (Settings preview).
    /// Returns only after the session has been configured; a throw means stay idle (ORA-SM-004).
    private func beginCapture(outputFormat: AVAudioFormat?,
                              excluding: Set<String>) throws -> AsyncStream<AnalyzerInput> {
        guard !running else { throw CaptureError.sessionStartFailed("already running") }
        guard let device = chosenDevice(excluding: excluding) else { throw CaptureError.noInputDevice }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: device) }
        catch { throw CaptureError.sessionStartFailed(error.localizedDescription) }
        currentDeviceUID = device.uniqueID
        // The single line that answers "which mic, in what format, converting to what?" — the three
        // facts every silent-capture report needs and none of which were previously recoverable.
        Log.audio.notice("Capture start: \(device.localizedName, privacy: .public) native=\(AVAudioFormat(cmAudioFormatDescription: device.activeFormat.formatDescription), privacy: .public) target=\(outputFormat?.description ?? "metering (no conversion)", privacy: .public)")

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        // Seed the watchdog clock at start: the grace period runs from here, so a session that never
        // delivers a single buffer is detected on the same timer as one that stops mid-recording.
        lastBufferBox.withLock { $0 = ContinuousClock.now }
        hasDeliveredBox.withLock { $0 = false }
        let sink = CaptureSink(outputFormat: outputFormat, levelBox: levelBox,
                               lastBufferBox: lastBufferBox, hasDeliveredBox: hasDeliveredBox,
                               clipBox: clipBox, yield: { cont.yield($0) })
        self.sink = sink
        output.setSampleBufferDelegate(sink, queue: captureQueue)

        // ALL session mutation (config + startRunning) runs on the serial sessionQueue, ordered AFTER
        // any pending stop()'s stopRunning — but *asynchronously*, so the MainActor never blocks
        // waiting on stopRunning (ORA-CAP-004/013). The one throwable step that must gate `.recording`
        // — opening the device — already happened above via AVCaptureDeviceInput(device:); canAdd
        // failures here are effectively impossible for audio and are logged, not thrown.
        // Pin the delivered format to MONO Float32 instead of accepting whatever the device is in
        // (ORA-CAP-001). Left to itself, `AVCaptureAudioDataOutput` hands over the hardware's native
        // format, and for a stereo USB microphone (Yeti X, Brio 505) that is 2-channel 24-bit packed
        // LPCM — a format with two fatal properties:
        //
        //   1. `AVAudioPCMBuffer` exposes no channel-data accessor for 24-bit, so `PCMConverter.rms`
        //      returns 0 for every buffer: a permanently flat waveform even while audio flows.
        //   2. `AVAudioConverter` downmixing 2ch→1ch reports success and produces SILENCE, so the
        //      recognizer receives nothing but zeros and every dictation comes back empty.
        //
        // Both failures are invisible — no error, no throw, capture "running" the whole time — and
        // only stereo mics are affected, which is why the built-in (mono) microphone always worked.
        // Asking for mono up front makes the capture pipeline do the downmix and leaves `PCMConverter`
        // with nothing but a sample-rate change.
        output.audioSettings = Self.monoFloatSettings

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
        lastBufferBox.withLock { $0 = nil }
        hasDeliveredBox.withLock { $0 = false }
        clipBox.withLock { $0 = nil }
        currentDeviceUID = nil
    }

    // MARK: Device selection (ORA-CAP-002)

    /// The outcome of resolving `MicSelection` to a device, plus whether it's a substitute — so the
    /// Settings readout can show the effective mode instead of silently implying the picked one
    /// (ORA-CAP-025).
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

    private func chosenDevice(excluding: Set<String>) -> AVCaptureDevice? {
        Self.resolveChoice(excluding: excluding).device
    }

    /// Resolve the current `MicSelection` to a device + substitution reason. O(1) Core Audio IPC on the
    /// common (as-selected) path — the hotkey→capture-start hot path — enumerating only on the cold
    /// garbage-default/absent-pin fallback (see `resolveUID`).
    static func resolveChoice(excluding: Set<String> = []) -> MicChoice {
        let (uid, substituted) = resolveUID(Settings.shared.micSelection, using: .live,
                                            excluding: excluding)
        guard let uid, let dev = AVCaptureDevice(uniqueID: uid) else {
            return MicChoice(device: nil, substituted: substituted)
        }
        return MicChoice(device: dev, substituted: substituted)
    }

    /// PURE selection decision over an injected `DeviceProvider` — no hardware, no AVCaptureDevice
    /// materialization — so every fallback/substitution branch is headlessly testable (ORA-CAP-012).
    /// `substituted` is true when the returned UID isn't the one the selection asked for. Returns nil
    /// `uid` only when NOTHING is usable, so the caller throws `noInputDevice` instead of silently
    /// capturing a dead device (ORA-CAP-006).
    /// `excluding` holds UIDs that already failed during this dictation. A device that dies without
    /// faulting the session — the watchdog's primary case — still enumerates and still passes
    /// `isUsableInput`, so without this the failover resolves straight back to it and burns every
    /// attempt on the mic that just died (SPEC E6: the best *remaining* input).
    static func resolveUID(_ selection: MicSelection, using p: DeviceProvider,
                           excluding: Set<String> = []) -> (uid: String?, substituted: Bool) {
        // One place to apply the exclusion, so no branch below can forget it.
        let usable: @MainActor (String) -> Bool = { !excluding.contains($0) && p.isUsable($0) }
        switch selection {
        case .automatic:
            let (uid, fellBack) = automaticUID(using: p, usable: usable)   // fellBack IS the substitution
            return (uid, fellBack)
        case .builtIn:
            if let uid = p.builtInUID(), usable(uid) { return (uid, false) }
            return (bestUsableUID(using: p, usable: usable), true)   // no built-in → substitute (nil if nothing usable)
        }
    }

    /// System default if usable, else the best usable input. `fellBack` is true when the default was
    /// unusable and we substituted.
    private static func automaticUID(using p: DeviceProvider,
                                     usable: @MainActor (String) -> Bool) -> (uid: String?, fellBack: Bool) {
        if let uid = p.defaultInputUID(), usable(uid) { return (uid, false) }
        return (bestUsableUID(using: p, usable: usable), true)
    }

    /// Best usable input UID: prefer the built-in, else the first usable present device. Consults
    /// `orderedInputUIDs` (enumeration) — only reached on the cold fallback path, never the hot path.
    private static func bestUsableUID(using p: DeviceProvider,
                                      usable: @MainActor (String) -> Bool) -> String? {
        if let uid = p.builtInUID(), usable(uid) { return uid }
        return p.orderedInputUIDs().first(where: usable)
    }

    /// The built-in input UID, memoized — INCLUDING the negative result, so a Mac with no built-in
    /// transport doesn't re-enumerate on every record start (ORA-CAP-007). A cached *positive* self-
    /// heals via the O(1) `isUsableInput` check; the cache is dropped on a Core Audio device change by
    /// the process-lifetime listener installed below, so a stale UID can't stick.
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
    /// A single PROCESS-lifetime device-change listener that drops the memoized UID, so the NEGATIVE
    /// memo re-probes when a built-in mic reappears (clamshell/undock/replug) even with Settings
    /// closed (ORA-CAP-024) — otherwise `.builtIn` mode stays stuck at "no built-in" indefinitely.
    /// This is the ONLY invalidator, and it must stay process-lifetime: the Settings meter's own
    /// device-change listeners are registered only while that window is open and metering.
    private static var invalidationListenerInstalled = false
    private static func installBuiltInInvalidationListenerIfNeeded() {
        guard !invalidationListenerInstalled else { return }
        invalidationListenerInstalled = true
        let (_, status) = CoreAudioSupport.addSystemListener(kAudioHardwarePropertyDevices) { _, _ in
            MainActor.assumeIsolated { AudioCapture.builtInCache = .unknown }
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
                        self.onUnrecoverableFailure?("Lost the microphone.")
                    }
                }
            }
        }
    }
}
