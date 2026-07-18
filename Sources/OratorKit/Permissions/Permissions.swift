import Foundation
import AVFoundation
import ApplicationServices
import AppKit

/// The TCC permissions Orator needs (§6.4).
public enum PermissionKind: CaseIterable, Sendable, Hashable {
    case microphone
    case accessibility

    public var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }

    /// One-line reason the permission is needed. Canonical copy so the onboarding step and any
    /// menu-bar remediation surface read the SAME words (can't drift — cf. `ModelStatus.summary`).
    public var purpose: String {
        switch self {
        case .microphone: return "To capture your speech."
        case .accessibility: return "To place text into the focused field."
        }
    }

    /// Deep link to the exact Privacy & Security pane (ORA-PERM-001).
    public var settingsURL: URL {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .accessibility: "Privacy_Accessibility"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }

    /// The `tccutil` service name for this permission (used to fully revoke a stuck grant).
    var tccService: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Accessibility"
        }
    }
}

public extension Set where Element == PermissionKind {
    /// Deterministic display order for user-facing lists: microphone (record-blocking) before
    /// accessibility, matching the menu's remediation-item order. A `Set` is unordered, so every
    /// surface rendering missing permissions must sort through this.
    var ordered: [PermissionKind] {
        PermissionKind.allCases.filter { self.contains($0) }
    }
}

/// Model-asset lifecycle for the not-ready surface (E3/E4, ORA-ASR-006).
public enum ModelStatus: Equatable, Sendable {
    case missing        // supported but not installed
    case downloading(fractionCompleted: Double)
    case installed
    case failed(String) // legible reason; retryable (never fatal)
    case unsupported    // locale not supported on this device

    /// Canonical one-line status for the on-device speech model. Single source of truth for BOTH
    /// not-ready surfaces — onboarding step detail and menu-bar remediation banner — so they can't
    /// drift (mirrors `PermissionKind.purpose`).
    public var summary: String {
        switch self {
        case .installed: return "Installed and ready."
        case .downloading(let f): return "Downloading… \(Int(f * 100))%"
        case .missing: return "A one-time on-device download — no account, no cloud."
        case .failed(let why): return "Download didn't finish — \(why). You can retry."
        case .unsupported: return "Not available for this language on this Mac."
        }
    }
}

/// Reads and requests TCC permissions. All checks are cheap and synchronous where the
/// platform allows, so `PermissionsManager` can be re-polled on focus (ORA-PERM-002).
@MainActor
public final class PermissionsManager {
    public init() {}

    // MARK: Reads (no prompt)

    public var microphoneGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    /// Effective Accessibility trust. `AXIsProcessTrusted()` reflects the *live* effective
    /// grant, so a stale entry that is toggled off — or a reinstall whose signature no longer
    /// matches the TCC record — reads as untrusted here (ORA-PERM-002).
    public var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// The set of required permissions currently missing.
    public func missing() -> Set<PermissionKind> {
        var out: Set<PermissionKind> = []
        if !microphoneGranted { out.insert(.microphone) }
        if !accessibilityGranted { out.insert(.accessibility) }
        return out
    }

    // MARK: Requests / deep links (ORA-PERM-001)

    public func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Prompt for Accessibility with the system's own dialog, then the user completes it in Settings.
    @discardableResult
    public func promptAccessibility() -> Bool {
        // Use the literal key string to avoid referencing the non-concurrency-safe imported global.
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    /// Fully revoke a grant with `tccutil reset <service> <bundle-id>`, so the user can escape a
    /// *stuck* permission (e.g. Accessibility that reads as trusted in System Settings but is
    /// effectively off after a re-sign/reinstall — `AXIsProcessTrusted()` returns false and toggling
    /// won't re-prompt). After a reset the entry is cleared and the next grant is a fresh prompt.
    /// A relaunch may be needed for the change to take full effect.
    public func reset(_ kind: PermissionKind) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.grgmrr.orator"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", kind.tccService, bundleID]
        do { try p.run(); p.waitUntilExit() }
        catch { Log.session.error("tccutil reset \(kind.tccService) failed: \(error.localizedDescription)") }
    }
}
