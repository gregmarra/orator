import Foundation

/// The Settings microphone readout, as PURE decisions over plain values.
///
/// These were private members of `SettingsView`, which made ORA-CAP-025 (a substituted selection must
/// read as "Automatic (name)") untestable on the newest, least battle-tested surface in the app. The
/// layer below already established the pattern: `AudioCapture.resolveUID` is pure over an injected
/// `DeviceProvider` and has a decision-table test (ORA-CAP-012). This is the same seam for the
/// presentation layer.
enum MicStatus {

    /// The compact status line under the level bar: the *effective* mode plus the resolved device,
    /// e.g. "Automatic (MacBook Air Microphone)". Also covers the permission, can't-open, and
    /// no-device states.
    ///
    /// - Parameters:
    ///   - permissionDenied: microphone TCC access is off — outranks everything else, since nothing
    ///     below it can be true in a useful way while the mic can't be opened at all.
    ///   - openFailure: name of a device that resolved but couldn't be opened (in use by another app).
    ///   - resolvedName: the meter's name for the resolved device.
    ///   - selection: the user's stored policy.
    ///   - substituted: true when the resolved device is NOT the one `selection` asked for.
    static func text(permissionDenied: Bool,
                            openFailure: String?,
                            resolvedName: String?,
                            selection: MicSelection,
                            substituted: Bool,
                            clipping: Bool = false) -> String {
        if permissionDenied { return "Microphone access is off — enable it in System Settings" }
        if let openFailure { return "\(openFailure) unavailable — may be in use" }
        // Ranked above the normal readout: the device IS working, but it is being driven into
        // distortion, which costs accuracy in a way nothing downstream can undo.
        if clipping { return "Input is too loud — lower the microphone gain" }
        guard let name = resolvedName else { return "No microphone available" }
        // ORA-CAP-025: a selection we couldn't honour is effectively automatic and must SAY so, rather
        // than naming a mode that isn't in force. This previously applied only to the per-device pin,
        // which left `.builtIn` on a Mac with no built-in mic reading "Built-in (Some USB Mic)" — the
        // exact claim the rule exists to prevent. It now covers every substituted selection.
        if substituted { return "Automatic (\(name))" }
        switch selection {
        case .automatic: return "Automatic (\(name))"
        case .builtIn:   return "Built-in (\(name))"
        }
    }
}
