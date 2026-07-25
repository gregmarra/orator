import AppKit
import QuartzCore

/// The always-present menu-bar item (ORA-IND-001) and its menu (ORA-IND-002). The icon encodes the
/// four states; the menu exposes recovery entries, permission/asset status when relevant, settings,
/// and quit.
@MainActor
public final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private weak var coordinator: SessionCoordinator?

    public var onOpenSettings: (() -> Void)?
    public var onQuit: (() -> Void)?
    public var onFixReadiness: (() -> Void)?
    public var onCancelDictation: (() -> Void)?
    public var onGrantMicrophone: (() -> Void)?
    public var onGrantAccessibility: (() -> Void)?
    /// Called when the menu is about to open, so readiness can be re-checked even for an accessory
    /// app that rarely activates (ORA-PERM-002).
    public var onMenuWillOpen: (() -> Void)?

    public init(coordinator: SessionCoordinator) {
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.coordinator = coordinator
        super.init()
        // macOS standardizes the menu-bar slot width, so a smaller length does NOT shrink the click
        // highlight (verified) — the value barely matters. Use the idiomatic square metric, matching
        // Apple's own square menu-bar items.
        item.length = NSStatusItem.squareLength
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()   // first paint (coordinator is already assigned, so its glyph resolves)
    }

    /// Reflect the current glyph in the menu-bar icon (ORA-IND-001, ORA-PERM-003, ORA-ACT-006).
    /// Deliberately minimal: ORANGE waveform while recording, WHITE waveform otherwise — the notch
    /// indicator carries the in-progress/processing detail, so the menu bar stays calm. (A white
    /// exclamation triangle when setup is needed.)
    public func updateIcon() {
        guard let button = item.button, let glyph = coordinator?.glyph else { return }
        button.toolTip = statusTooltip
        button.setAccessibilityLabel(Self.accessibilityLabel(for: glyph))
        switch glyph {
        case .recording:       applyTint(.orange, to: button)
        case .ready, .working: applyTint(.white, to: button)     // notch carries the processing detail
        case .notReady:        applyTint(.notReady, to: button)
        }
    }

    /// The three visual treatments the menu-bar icon can show, tracked so `updateIcon` (which fires on
    /// every level/elapsed tick) only touches the button on a REAL change — the crossfade never restarts.
    private enum Tint: Equatable { case orange, white, notReady }
    private var currentTint: Tint?

    /// Set the icon to `tint`, crossfading via a `CATransition` (render server) not a main-thread Timer.
    /// Fixes the record-start "strobe": at record-start the main actor stalls (SpeechAnalyzer setup +
    /// the indicator's expand spring), so a per-frame Timer fade froze then jumped — visible only on the
    /// way UP, since record-end has an idle main thread. A render-server crossfade is immune to
    /// main-thread stalls. Idempotent: repeated same-tint calls are no-ops, so per-tick updateIcon churn
    /// can't restart or strobe it.
    private func applyTint(_ tint: Tint, to button: NSStatusBarButton) {
        guard tint != currentTint else { return }
        let crossfade = currentTint != nil               // no dissolve on the very first paint
        currentTint = tint
        if crossfade {
            button.wantsLayer = true
            let fade = CATransition()
            fade.type = .fade
            // Match the notch's paired motion so they read as one: turning ORANGE coincides with the
            // notch springing OPEN (record start); returning to WHITE coincides with it collapsing.
            // Both durations come from IndicatorMetrics so they can't drift.
            fade.duration = (tint == .orange) ? IndicatorMetrics.expandDuration
                                              : IndicatorMetrics.collapseDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            button.layer?.add(fade, forKey: "waveformTint")
        }
        switch tint {
        case .orange:   button.image = symbolImage("waveform", accessibility: "Orator", tint: .systemOrange)
        case .white:    button.image = symbolImage("waveform", accessibility: "Orator", tint: nil)  // adaptive white
        case .notReady: button.image = symbolImage("exclamationmark.triangle.fill", accessibility: "Orator — not ready", tint: nil)
        }
    }

    /// Build an SF Symbol image. A non-nil `tint` bakes a palette colour in (non-template, since
    /// `contentTintColor` does NOT colour a non-template symbol); nil ⇒ adaptive template white.
    private func symbolImage(_ name: String, accessibility: String, tint: NSColor?) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let config = tint.map { cfg.applying(.init(paletteColors: [$0])) } ?? cfg
        let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibility)?
            .withSymbolConfiguration(config)
        img?.isTemplate = (tint == nil)
        return img
    }

    private static func accessibilityLabel(for glyph: IndicatorGlyph) -> String {
        switch glyph {
        case .ready:     return "Orator, ready"
        case .recording: return "Orator, recording"
        case .working:   return "Orator, transcribing"
        case .notReady:  return "Orator, setup needed"
        }
    }

    /// Readiness is a STANDING condition; `lastError` is an event. A stale error must not hide a live,
    /// actionable "grant Microphone, Accessibility" — so readiness wins whenever it isn't `.ready`, and
    /// the error is consulted only while it's still recent (`recentError`).
    /// Test seam for the readiness-vs-error precedence rule below.
    var tooltipForTesting: String { statusTooltip }

    private var statusTooltip: String {
        switch coordinator?.readiness {
        case .ready, .none:
            if let err = coordinator?.recentError { return "Orator — \(err)" }
            return "Orator — ready"
        case .degradedHotkey: return "Orator — hotkey degraded (secure input active)"
        case .needsPermission(let p): return "Orator — grant \(p.ordered.map(\.title).joined(separator: ", "))"
        case .needsModel: return "Orator — model setup needed"
        }
    }

    // MARK: Menu (rebuilt on open + when the buffer changes)

    public func menuNeedsUpdate(_ menu: NSMenu) {
        onMenuWillOpen?()
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        // While recording, offer a Cancel item — the degraded cancel fallback (E10) when the Escape
        // tap is unavailable, and a discoverable abort in all cases.
        if coordinator?.state == .recording {
            addItem(menu, "Cancel Dictation", #selector(cancelDictation), symbol: "mic.slash")
            menu.addItem(.separator())
        }

        // Not-ready banner + actionable remediation (ORA-IND-002, §10.3 name-the-fix). These are
        // plain AppKit menu items — the reliable, crash-free way to run setup.
        if let readiness = coordinator?.readiness, readiness != .ready {
            let banner = NSMenuItem(title: readinessTitle(readiness), action: nil, keyEquivalent: "")
            banner.isEnabled = false
            menu.addItem(banner)
            switch readiness {
            case .needsPermission(let missing):
                if missing.contains(.microphone) {
                    addItem(menu, "Grant Microphone…", #selector(grantMicrophone), symbol: "mic")
                }
                if missing.contains(.accessibility) {
                    addItem(menu, "Grant Accessibility…", #selector(grantAccessibility), symbol: "accessibility")
                }
            case .needsModel:
                addItem(menu, "Retry Model Download…", #selector(fixReadiness), symbol: "arrow.down.circle")
            default:
                break
            }
            menu.addItem(.separator())
        }

        // Recovery entries (ORA-REC-001/002). A real section header (macOS 14+) gets the system's
        // header styling and is skipped by keyboard navigation — unlike a disabled pseudo-header.
        let entries = coordinator?.recovery.entries ?? []
        if entries.isEmpty {
            let none = NSMenuItem(title: "No Recent Dictations", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            menu.addItem(.sectionHeader(title: "Recent Dictations"))
            for entry in entries {
                let mi = NSMenuItem(title: entry.menuTitle, action: #selector(copyEntry(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = entry.id
                mi.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
                mi.toolTip = "Click to copy to the clipboard"
                menu.addItem(mi)
            }
        }

        menu.addItem(.separator())
        // Settings is the SINGLE entry point (ORA-CFG-001): setup is reached from the button inside it,
        // not from a competing top-level item.
        addItem(menu, "Settings…", #selector(openSettings), symbol: "gearshape", keyEquivalent: ",")
        addItem(menu, "Quit Orator", #selector(quit), keyEquivalent: "q")
    }

    private func readinessTitle(_ r: Readiness) -> String {
        switch r {
        case .ready: return ""
        case .degradedHotkey: return "Hotkey degraded — secure input is active"
        case .needsPermission(let p): return "Missing: \(p.ordered.map(\.title).joined(separator: ", "))"
        case .needsModel(let status): return "Speech model — \(status.summary)"
        }
    }

    // MARK: Actions

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        coordinator?.recovery.copyToPasteboard(id)
    }
    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, symbol: String? = nil, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        menu.addItem(item)
    }

    @objc private func openSettings() { onOpenSettings?() }
    @objc private func quit() { onQuit?() }
    @objc private func fixReadiness() { onFixReadiness?() }
    @objc private func cancelDictation() { onCancelDictation?() }
    @objc private func grantMicrophone() { onGrantMicrophone?() }
    @objc private func grantAccessibility() { onGrantAccessibility?() }
}
