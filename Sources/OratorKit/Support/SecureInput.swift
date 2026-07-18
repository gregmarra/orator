import Carbon.HIToolbox

/// Global secure keyboard entry state (ORA-ACT-006 / ORA-SEC-001 / E10). When active system-wide
/// (e.g. a password field elsewhere has secure input engaged), a CGEvent tap goes deaf, so Escape
/// capture degrades and the hotkey capability is reflected as degraded.
public enum SecureInput {
    public static var isGloballyActive: Bool { IsSecureEventInputEnabled() }
}
