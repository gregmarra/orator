import Foundation

/// The Settings microphone readout, as PURE decisions over plain values.
///
/// These were private members of `SettingsView`, which made two named requirements — the
/// ORA-CAP-005 "a fallen-back pin reads as Automatic" rule and ORA-CAP-011 name-collision
/// disambiguation — untestable on the newest, least battle-tested surface in the app. The layer below
/// already established the pattern: `AudioCapture.resolveUID` is pure over an injected
/// `DeviceProvider` and has a decision-table test. This is the same seam for the presentation layer.
enum MicStatus {

    /// The compact status line under the level bar: the *effective* mode plus the resolved device,
    /// e.g. "Automatic (MacBook Air Microphone)". Also covers the permission, can't-open, and
    /// no-device states.
    ///
    /// - Parameters:
    ///   - permissionDenied: microphone TCC access is off — outranks everything else, since nothing
    ///     below it can be true in a useful way while the mic can't be opened at all.
    ///   - openFailure: name of a device that resolved but couldn't be opened (in use by another app).
    ///   - liveName: the picker's (Core Audio) name for the resolved UID, preferred so the list and
    ///     the status line can't disagree.
    ///   - resolvedName: the meter's own name for the resolved device, used when `liveName` is absent.
    ///   - selection: the user's stored policy.
    ///   - substituted: true when the resolved device is NOT the one `selection` asked for.
    static func text(permissionDenied: Bool,
                            openFailure: String?,
                            liveName: String?,
                            resolvedName: String?,
                            selection: MicSelection,
                            substituted: Bool,
                            clipping: Bool = false) -> String {
        if permissionDenied { return "Microphone access is off — enable it in System Settings" }
        if let openFailure { return "\(openFailure) unavailable — may be in use" }
        // Ranked above the normal readout: the device IS working, but it is being driven into
        // distortion, which costs accuracy in a way nothing downstream can undo.
        if clipping { return "Input is too loud — lower the microphone gain" }
        guard let name = liveName ?? resolvedName else { return "No microphone available" }
        switch selection {
        case .automatic: return "Automatic (\(name))"
        case .builtIn:   return "Built-in (\(name))"
        // A present pin shows its own name; a fallen-back pin is effectively automatic, and must say so
        // rather than implying the pinned device is in use (ORA-CAP-005).
        case .device:    return substituted ? "Automatic (\(name))" : name
        }
    }

    /// A picker row label: annotate the system default, and disambiguate identical names (two of the
    /// same USB camera) with a short UID suffix so the user can tell them apart (ORA-CAP-011).
    static func rowLabel(for device: CoreAudioSupport.InputDevice,
                                among devices: [CoreAudioSupport.InputDevice],
                                defaultUID: String?) -> String {
        let collides = devices.filter { $0.name == device.name }.count > 1
        var label = device.name
        if collides { label += " (\(device.uid.suffix(4)))" }
        if device.uid == defaultUID { label += " (default)" }
        return label
    }
}
