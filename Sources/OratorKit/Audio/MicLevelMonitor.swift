import Foundation
import CoreAudio
@preconcurrency import AVFoundation
import Observation
import os

/// Drives the Settings input-level meter. Runs a private `AudioCapture` on the currently-selected
/// device (via the same `AudioCapture.resolveChoice()` the real recording uses), so the bar shows
/// precisely what a recording would capture. Lives only while the Settings pane is open — it is never
/// on the hotkey→capture-start path, so its cost doesn't affect start latency.
@MainActor
@Observable
final class MicLevelMonitor {
    /// Smoothed input level, 0…1, for display.
    private(set) var level: Float = 0
    /// Name of the device currently being metered (what "Automatic"/a pin resolves to right now), or
    /// nil if no usable input exists.
    private(set) var resolvedName: String?
    /// UID of that device, so the view can prefer the picker's name for it (consistent naming).
    private(set) var resolvedUID: String?
    /// True when the resolved device is a *substitute* for the selection (garbage default, or no
    /// built-in when Built-in is selected) — the readout uses it to show the effective mode
    /// (ORA-CAP-025).
    private(set) var substituted = false
    /// Set when a real, resolved device could not be *opened* (busy/exclusive) — distinct from
    /// "no device exists", so the readout doesn't wrongly claim the mic is missing.
    private(set) var openFailure: String?
    /// Set when microphone TCC access isn't granted — capturing then "succeeds" but delivers silence
    /// (a permanently flat bar), so we detect it up front and tell the user to enable access.
    private(set) var permissionDenied = false
    /// True while the input is hitting the rails. Distortion from clipping degrades recognition and
    /// no downstream setting recovers it — the only fix is lowering the gain, so it has to be visible.
    private(set) var clipping = false

    @ObservationIgnored private let capture = AudioCapture()
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var running = false

    /// Core Audio listener blocks, kept so we can remove exactly what we added. Registered while the
    /// meter is live and torn down with it, so a device change can't re-acquire the mic once the
    /// Settings window is inactive — the gate the view used to apply externally.
    @ObservationIgnored
    private var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    @ObservationIgnored private var restartPending = false
    /// Bumped on teardown so an in-flight debounced restart from a previous session no-ops.
    @ObservationIgnored private var restartGeneration = 0

    init() {}

    /// Start metering the currently-selected device. Idempotent.
    func start() {
        // Listen regardless of whether capture then succeeds: if no usable input exists right now, a
        // device appearing later is exactly the event that should bring the meter to life.
        listenForDeviceChanges()
        guard !running else { return }
        let choice = AudioCapture.resolveChoice()
        resolvedName = choice.device?.localizedName
        resolvedUID = choice.device?.uniqueID
        substituted = choice.substituted
        openFailure = nil
        permissionDenied = false
        clipping = false
        level = 0
        // Denied TCC access doesn't throw — it silently delivers no samples — so detect it up front.
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            permissionDenied = true
            return
        }
        guard choice.device != nil else { return }   // nothing usable → readout shows "no microphone"
        do {
            // Metering: the sink derives RMS from the raw buffer and never yields — so the stream
            // stays empty and we don't consume it (no backlog to drain).
            _ = try capture.startMetering()
            running = true
            poll = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    self.level = Self.smooth(self.level, self.capture.currentLevel)
                    self.clipping = self.capture.isClipping
                    try? await Task.sleep(for: .milliseconds(33))   // ~30 Hz, UI-only
                }
            }
        } catch {
            // The device exists but couldn't be opened (busy/exclusive/TCC) — keep its name and say so,
            // rather than implying no mic exists.
            openFailure = resolvedName
            level = 0
        }
    }

    /// Stop metering and release the mic. Idempotent.
    func stop() {
        stopListening()
        poll?.cancel(); poll = nil
        if running { capture.stop() }
        running = false
        level = 0
    }

    // MARK: Device-change tracking

    /// Re-meter when the set of inputs or the system default changes (AirPods connecting, a hub
    /// waking) so the readout and the bar follow what a recording would actually capture. This lived
    /// in a separate `AudioDeviceList` whose only other job was populating a per-device picker; with
    /// that picker gone (ORA-CAP-002), the meter is the sole consumer and owns it directly.
    private func listenForDeviceChanges() {
        guard registered.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            // Delivered on the main queue, so assumeIsolated is safe. Weak so the listener never keeps
            // the monitor alive past stop().
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.scheduleRestart() }
            }
            let (addr, status) = CoreAudioSupport.addSystemListener(selector, block)
            if status == noErr { registered.append((addr, block)) }
            else { Log.audio.error("Failed to add CoreAudio listener for \(selector, privacy: .public): \(status)") }
        }
    }

    private func stopListening() {
        for (addr, block) in registered {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a,
                                                   DispatchQueue.main, block)
        }
        registered.removeAll()
        restartGeneration &+= 1   // cancel any pending debounced restart from this session
        restartPending = false
    }

    /// Coalesce a burst of change callbacks (docks/hubs re-registering) into one restart, and — the
    /// load-bearing part — get off the Core Audio callback before tearing the capture session down,
    /// since `restart()` removes the very listener block that is currently executing.
    private func scheduleRestart() {
        guard !restartPending else { return }
        restartPending = true
        let gen = restartGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.restartGeneration else { return }
                self.restartPending = false
                self.restart()
            }
        }
    }

    /// Re-resolve and meter the newly-selected device (call when the selection, system default, or
    /// device list changes). No-op when the resolved device is unchanged, so plug/unplug bursts and
    /// redundant onChange fires don't needlessly tear down and rebuild the capture session (ORA-CAP-008).
    func restart() {
        let newUID = AudioCapture.resolveChoice().device?.uniqueID
        if running, newUID == resolvedUID { return }
        stop()
        start()
    }

    /// Fast attack, slow decay, with gain. Raw speech RMS is ~0.01–0.1, so scale up and clamp — a VU
    /// meter should jump to peaks instantly and fall back smoothly.
    private static func smooth(_ current: Float, _ raw: Float) -> Float {
        let target = min(1, raw * 12)
        return target > current ? target : current * 0.82 + target * 0.18
    }
}
