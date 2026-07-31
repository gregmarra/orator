/// The dictation lifecycle state (§7.2). The SessionCoordinator is the single owner.
///
/// Transitions (all funneled through the coordinator, processed one at a time):
///   idle → recording            (hotkey, if ready)
///   recording → finalizing      (hotkey / max-duration)
///   recording → idle            (Escape / cancel)
///   recording → recording       (survivable device change — same session)
///   finalizing → inserting      (got final, or hit finalization cap)
///   inserting → idle
public enum SessionState: String, Equatable, Sendable {
    case idle
    case recording
    case finalizing
    case inserting
}

/// Whether Orator can actually start a dictation right now. Kept separate from
/// `SessionState`: readiness gates the idle→recording transition and drives the
/// "not-ready" status icon (ORA-PERM-003, ORA-IND-001), but is not part of the
/// per-dictation lifecycle.
public enum Readiness: Equatable, Sendable {
    /// Warm and able to dictate.
    case ready
    /// One or more required permissions are missing (§6.4).
    case needsPermission(Set<PermissionKind>)
    /// The on-device model asset is not yet usable (§8.4 / E3–E4).
    case needsModel(ModelStatus)
    /// The hotkey/Escape path is degraded because global secure keyboard entry is
    /// active system-wide (ORA-ACT-006 / ORA-SEC-001 / E10). Dictation itself may
    /// still work; the control is what's impaired.
    case degradedHotkey

    public var canStartDictation: Bool {
        switch self {
        case .ready, .degradedHotkey: return true
        // Microphone is the only record-blocking permission; an Accessibility-only gap still allows
        // recording, with insertion routed to the recovery buffer (E2 / ORA-INS §8.6).
        case .needsPermission(let perms): return !perms.contains(.microphone)
        case .needsModel: return false
        }
    }

    /// One user-facing phrase naming what is wrong — empty when nothing is. The SINGLE definition,
    /// shared by every surface that has to explain a blocked dictation: the menu-bar banner and the
    /// indicator notice shown when the hotkey is pressed while not ready. Previously this wording was
    /// private to `StatusItemController`, so the hotkey path had nothing to say and said nothing.
    public var shortReason: String {
        switch self {
        case .ready: return ""
        case .degradedHotkey: return "Hotkey degraded — secure input is active"
        case .needsPermission(let p): return "Missing: \(p.ordered.map(\.title).joined(separator: ", "))"
        case .needsModel(let status): return "Speech model — \(status.summary)"
        }
    }
}

/// The four icon states the menu-bar item must encode (ORA-IND-001).
public enum IndicatorGlyph: Equatable, Sendable {
    case ready              // warm, idle
    case recording          // capturing
    case working            // finalizing / inserting
    case notReady           // permission or model issue

    /// Derive the menu-bar glyph from the two orthogonal facts.
    public static func from(state: SessionState, readiness: Readiness) -> IndicatorGlyph {
        if !readiness.canStartDictation { return .notReady }
        switch state {
        case .idle: return .ready
        case .recording: return .recording
        case .finalizing, .inserting: return .working
        }
    }
}
