import Foundation
import CoreAudio
@preconcurrency import AVFoundation
import Observation
import os

/// Live list of selectable input devices for the Settings picker. Enumerates authoritatively via
/// CoreAudio (`CoreAudioSupport`) and refreshes whenever devices are plugged/unplugged or the system
/// default input changes, so a newly connected mic (e.g. a USB camera) appears without reopening
/// Settings.
///
/// This is the ONLY place full device enumeration belongs — it is driven by UI presence and CoreAudio
/// notifications, never by the hotkey→capture-start path (which resolves its device in O(1); see
/// `AudioCapture.chosenDevice`).
@MainActor
@Observable
final class AudioDeviceList {
    /// Present, non-garbage input devices (channels > 0), newest CoreAudio ordering.
    private(set) var devices: [CoreAudioSupport.InputDevice] = []
    /// UID of the current system default input, for annotating the "Automatic" choice.
    private(set) var defaultUID: String?

    /// Registered listener blocks, kept so we can remove exactly what we added.
    @ObservationIgnored
    private var registered: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    /// True while a debounced refresh is pending, so a burst of listener callbacks (docks/hubs/USB
    /// devices re-registering) collapses to a single enumeration instead of one per event.
    @ObservationIgnored
    private var refreshPending = false
    /// Bumped on stop() so an in-flight debounced refresh scheduled by a previous session no-ops
    /// instead of firing (or starving the next session's callbacks) after teardown (ORA-CAP-019).
    @ObservationIgnored
    private var refreshGeneration = 0

    init() {}

    /// Begin listening and populate immediately. Idempotent.
    func start() {
        guard registered.isEmpty else { return }
        refresh()
        listen(kAudioHardwarePropertyDevices)
        listen(kAudioHardwarePropertyDefaultInputDevice)
    }

    /// Stop listening. Pair with `start()` on view disappear so we don't leak CoreAudio listeners.
    func stop() {
        for (addr, block) in registered {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, DispatchQueue.main, block)
        }
        registered.removeAll()
        refreshPending = false
        refreshGeneration &+= 1   // cancel any pending debounced refresh from this session
    }

    private func refresh() {
        // Only devices we can actually capture from — the same predicate selection uses, so the picker
        // and the resolver can't disagree (ORA-CAP-016).
        let list = CoreAudioSupport.inputDeviceList().filter { AudioCapture.isVendableInput(uid: $0.uid) }
        devices = list
        defaultUID = CoreAudioSupport.defaultInputUID()
        // Remember names so a later-unplugged *pinned* device can still be shown by name
        // ("Work USB Camera (unavailable)") — one dictionary read/write, not one per device (ORA-CAP-009).
        Settings.shared.rememberDeviceNames(Dictionary(uniqueKeysWithValues: list.map { ($0.uid, $0.name) }))
    }

    /// Coalesce a burst of Core Audio change callbacks into one refresh (~150 ms window). Cancellable
    /// via `refreshGeneration` so a stop()+start() during the window can't be starved by a stale block.
    /// (The built-in cache is invalidated by AudioCapture's own process-lifetime listener, not here.)
    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        let gen = refreshGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.refreshGeneration else { return }
                self.refreshPending = false
                self.refresh()
            }
        }
    }

    private func listen(_ selector: AudioObjectPropertySelector) {
        // Delivered on the main queue, so assumeIsolated is safe. `self` is @MainActor (hence Sendable);
        // weak so the listener never keeps the model alive past `stop()`.
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.scheduleRefresh()
                Log.audio.debug("Input device change; refresh scheduled")
            }
        }
        let (addr, status) = CoreAudioSupport.addSystemListener(selector, block)
        if status == noErr {
            registered.append((addr, block))
        } else {
            Log.audio.error("Failed to add CoreAudio listener for \(selector, privacy: .public): \(status)")
        }
    }
}
