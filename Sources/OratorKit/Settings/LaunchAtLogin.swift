import ServiceManagement

/// Launch-at-login via `SMAppService` (ORA-CFG-003). No login-item helper bundle needed.
public enum LaunchAtLogin {
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public static func set(_ enabled: Bool) {
        guard enabled != isEnabled else { return }   // already in the desired state
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.session.error("Launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
