import AppKit
import Foundation
import CoreAudio
@preconcurrency import AVFoundation
import Observation
import Speech
import os

/// Drives the Settings input-level meter. Runs a private `AudioCapture` on the currently-selected
/// device (via the same `AudioCapture.resolveChoice()` the real recording uses), so the bar shows
/// precisely what a recording would capture. Lives only while the Settings pane is open — it is never
/// on the hotkey→capture-start path, so its cost doesn't affect start latency.
///
/// Two owners, split by question. `AppDelegate` decides WHETHER the meter should exist at all (it
/// opens and closes the Settings window). This class decides whether to hold the microphone RIGHT
/// NOW, from AppKit notifications — because the alternative, a SwiftUI view gating it, cannot see a
/// display going to sleep and cannot be relied on to hear about its own window closing (ORA-CAP-026).
///
/// Every outside input — the capture, the device resolver, the device-change feed, both notification
/// centers, and the debounce delay — is injected, with the real ones supplied by `init()`. The bug this
/// class exists to prevent (the mic held open, orange indicator lit) is order-dependent and was never
/// reproduced by hand, so its orderings are pinned down by `MicLevelMonitorTests` instead.
@MainActor
@Observable
public final class MicLevelMonitor {
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

    @ObservationIgnored private let capture: any MeteringCapture
    @ObservationIgnored private let deviceChanges: any DeviceChangeSource
    @ObservationIgnored private let resolve: @MainActor () -> MeterChoice
    @ObservationIgnored private let isAuthorized: @MainActor () -> Bool
    @ObservationIgnored private let isAppActive: @MainActor () -> Bool
    @ObservationIgnored private let appCenter: NotificationCenter
    @ObservationIgnored private let workspaceCenter: NotificationCenter
    @ObservationIgnored private let restartDelay: Duration

    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var running = false
    // The three facts `sync` decides from. The last two are tracked separately rather than collapsed
    // into one "the user is present" flag because they genuinely disagree: at the lock screen the
    // display is awake while the app is not active, and one flag would let the display waking
    // re-acquire the microphone behind the lock.
    //
    // `settingsOpen` is the delegate's answer, set by `start`/`stop`.
    @ObservationIgnored private var settingsOpen = false
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var screensAwake = true
    /// AppKit/workspace observers held while Settings is open, so exactly what was added is removed.
    @ObservationIgnored private var lifecycleObservers: [(NotificationCenter, NSObjectProtocol)] = []

    /// The pending debounced restart, if any — non-nil IS "a restart is already scheduled", and
    /// cancelling it is what stops one from a previous session landing on this one.
    @ObservationIgnored private var restartTask: Task<Void, Never>?

    /// The production meter: a real `AudioCapture`, Core Audio device listeners, and AppKit's own
    /// notification centers.
    public convenience init() {
        self.init(capture: AudioCapture(label: "meter"),
                  deviceChanges: CoreAudioDeviceChanges(),
                  resolve: MeterChoice.live,
                  isAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
                  isAppActive: { NSApp.isActive },
                  appCenter: .default,
                  workspaceCenter: NSWorkspace.shared.notificationCenter,
                  restartDelay: .milliseconds(150))
    }

    /// Everything injected, for tests. No defaults on purpose: they would make `init()` ambiguous, and
    /// a test that silently got a real dependency could end up holding the real microphone.
    init(capture: any MeteringCapture,
         deviceChanges: any DeviceChangeSource,
         resolve: @escaping @MainActor () -> MeterChoice,
         isAuthorized: @escaping @MainActor () -> Bool,
         isAppActive: @escaping @MainActor () -> Bool,
         appCenter: NotificationCenter,
         workspaceCenter: NotificationCenter,
         restartDelay: Duration) {
        self.capture = capture
        self.deviceChanges = deviceChanges
        self.resolve = resolve
        self.isAuthorized = isAuthorized
        self.isAppActive = isAppActive
        self.appCenter = appCenter
        self.workspaceCenter = workspaceCenter
        self.restartDelay = restartDelay
    }

    /// Settings has opened: the meter should be live whenever the user is there to see it. Idempotent.
    public func start() {
        settingsOpen = true
        appActive = isAppActive()
        // Opening Settings takes a user at an awake screen. A wake that arrived while Settings was
        // closed went unheard (the observers were removed), so don't trust the stale sleep flag.
        screensAwake = true
        observeLifecycle()
        sync()
    }

    /// Settings has closed: the meter should be off and the microphone released. Idempotent.
    public func stop() {
        settingsOpen = false
        stopObservingLifecycle()
        sync()
    }

    /// **The rule, stated once:** hold the microphone only while Settings is open and the user is in
    /// front of the machine. Everything that can change one of those three facts calls this, and
    /// nothing else decides — so there is no path that can pause without a matching resume, or resume
    /// into a condition that should still be paused.
    private func sync() {
        if settingsOpen && appActive && screensAwake { beginMetering() } else { endMetering() }
    }

    /// Acquire the mic and start metering the currently-selected device. Idempotent.
    private func beginMetering() {
        // Listen regardless of whether capture then succeeds: if no usable input exists right now, a
        // device appearing later is exactly the event that should bring the meter to life.
        listenForDeviceChanges()
        guard !running else { return }
        let choice = resolve()
        resolvedName = choice.name
        resolvedUID = choice.uid
        substituted = choice.substituted
        openFailure = nil
        permissionDenied = false
        clipping = false
        level = 0
        // Denied TCC access doesn't throw — it silently delivers no samples — so detect it up front.
        guard isAuthorized() else {
            permissionDenied = true
            return
        }
        guard choice.uid != nil else { return }   // nothing usable → readout shows "no microphone"
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
    private func endMetering() {
        stopListening()
        poll?.cancel(); poll = nil
        capture.stop()   // unconditional: `capture` owns its own idempotence, and gating this on the
                         // monitor's `running` meant any desync between the two flags stranded the
                         // microphone open with no way back short of quitting (ORA-CAP-026)
        running = false
        level = 0
    }

    // MARK: Releasing the mic when nobody is looking (ORA-CAP-010)

    /// Keep `appActive` and `screensAwake` true to life.
    ///
    /// Two signals, each with its inverse, and neither is redundant: **app active** covers switching
    /// apps, locking the screen, and switching users (all of them hand the active app to something
    /// else), while **screens awake** covers the case that produces no such event and was the actual
    /// bug — walking away and letting the display sleep with Settings still frontmost. Machine sleep
    /// needs no entry of its own: the display always sleeps first.
    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        observe(appCenter, NSApplication.didResignActiveNotification) { $0.appActive = false }
        observe(appCenter, NSApplication.didBecomeActiveNotification) { $0.appActive = true }
        observe(workspaceCenter, NSWorkspace.screensDidSleepNotification) { $0.screensAwake = false }
        observe(workspaceCenter, NSWorkspace.screensDidWakeNotification) { $0.screensAwake = true }
    }

    /// Each observer only records the fact it learned; reconciling is this helper's job, so no
    /// notification can be wired up and then forget to act on itself.
    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ record: @escaping @MainActor (MicLevelMonitor) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                record(self)
                self.sync()
            }
        }
        lifecycleObservers.append((center, token))
    }

    private func stopObservingLifecycle() {
        for (center, token) in lifecycleObservers { center.removeObserver(token) }
        lifecycleObservers.removeAll()
    }

    // MARK: Device-change tracking

    /// Re-meter when the set of inputs or the system default changes (AirPods connecting, a hub
    /// waking) so the readout and the bar follow what a recording would actually capture. Registered
    /// while the meter is live and torn down with it, so a device change can't re-acquire the mic once
    /// `sync` has decided we shouldn't be holding it.
    private func listenForDeviceChanges() {
        // Weak so the listener never keeps the monitor alive past stop().
        deviceChanges.begin { [weak self] in self?.scheduleRestart() }
    }

    private func stopListening() {
        deviceChanges.end()
        restartTask?.cancel(); restartTask = nil   // drop a debounced restart from this session
    }

    /// Coalesce a burst of change callbacks (docks/hubs re-registering) into one restart, and — the
    /// load-bearing part — get off the Core Audio callback before tearing the capture session down,
    /// since `restart()` removes the very listener block that is currently executing.
    private func scheduleRestart() {
        guard restartTask == nil else { return }   // one pending restart per burst
        restartTask = Task { [weak self, restartDelay] in
            try? await Task.sleep(for: restartDelay)
            guard !Task.isCancelled, let self else { return }
            self.restartTask = nil                 // cleared first: `restart` tears the listeners down,
            self.restart()                         // and that path cancels whatever is pending
        }
    }

    /// Re-resolve and meter the newly-selected device (call when the selection, system default, or
    /// device list changes). No-op when the resolved device is unchanged, so plug/unplug bursts and
    /// redundant onChange fires don't needlessly tear down and rebuild the capture session (ORA-CAP-008).
    func restart() {
        let newUID = resolve().uid
        if running, newUID == resolvedUID { return }
        endMetering()
        sync()   // re-acquire only if we should be holding the mic at all — `sync` owns that decision,
                 // so a device change can't re-open it behind a closed window or a sleeping display
    }

    /// Fast attack, slow decay, with gain. Raw speech RMS is ~0.01–0.1, so scale up and clamp — a VU
    /// meter should jump to peaks instantly and fall back smoothly.
    private static func smooth(_ current: Float, _ raw: Float) -> Float {
        let target = min(1, raw * 12)
        return target > current ? target : current * 0.82 + target * 0.18
    }
}

// MARK: - Injection points

/// What the meter needs from a capture: `AudioCapture` in production, a counting fake in tests.
@MainActor
protocol MeteringCapture: AnyObject {
    var currentLevel: Float { get }
    var isClipping: Bool { get }
    func startMetering() throws -> AsyncStream<AnalyzerInput>
    /// Release the microphone. Must be idempotent: the meter calls it unconditionally (ORA-CAP-026).
    func stop()
}

extension AudioCapture: MeteringCapture {}

/// The meter's view of a resolved device — just the facts it shows and compares, so a test needn't
/// conjure an `AVCaptureDevice`. `uid == nil` means no usable input exists.
struct MeterChoice: Sendable, Equatable {
    var name: String?
    var uid: String?
    var substituted: Bool

    /// The same `AudioCapture.resolveChoice()` a real recording uses — O(1) on the as-selected path —
    /// so the bar shows precisely what a recording would capture.
    @MainActor static func live() -> MeterChoice {
        let choice = AudioCapture.resolveChoice()
        return MeterChoice(name: choice.device?.localizedName, uid: choice.device?.uniqueID,
                           substituted: choice.substituted)
    }
}

/// A feed of "the set of inputs or the system default changed". `begin` is idempotent, `end` removes
/// exactly what `begin` added, and `onChange` is delivered on the main actor.
@MainActor
protocol DeviceChangeSource: AnyObject {
    func begin(_ onChange: @escaping @MainActor () -> Void)
    func end()
}

/// Core Audio's system-object listeners for the device list and the default input. This lived in a
/// separate `AudioDeviceList` whose only other job was populating a per-device picker; with that
/// picker gone (ORA-CAP-002), the meter is the sole consumer.
@MainActor
final class CoreAudioDeviceChanges: DeviceChangeSource {
    /// Listener blocks, kept so we can remove exactly what we added.
    private var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    func begin(_ onChange: @escaping @MainActor () -> Void) {
        guard registered.isEmpty else { return }
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            // Delivered on the main queue, so assumeIsolated is safe.
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                MainActor.assumeIsolated { onChange() }
            }
            let (addr, status) = CoreAudioSupport.addSystemListener(selector, block)
            if status == noErr { registered.append((addr, block)) }
            else { Log.audio.error("Failed to add CoreAudio listener for \(selector, privacy: .public): \(status)") }
        }
    }

    func end() {
        for (addr, block) in registered {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a,
                                                   DispatchQueue.main, block)
        }
        registered.removeAll()
    }
}
