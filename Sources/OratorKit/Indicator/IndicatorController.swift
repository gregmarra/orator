import AppKit
import SwiftUI

/// Owns the indicator panel: shows it at a fixed size at record-start, positions it as a notch or
/// pill on the active screen, updates its content, and recomputes geometry on screen changes
/// (ORA-IND-011/012/014/015).
///
/// The hosting view renders `IndicatorRoot` from a persistent `IndicatorModel`, so state changes
/// (the dot↔spinner morph, the waveform) animate **in place** rather than snapping. Content-driven
/// sizing is disabled so streaming text never resizes the window (ORA-IND-012 / §11.2).
@MainActor
public final class IndicatorController {
    private let panel = IndicatorPanel()
    private let model = IndicatorModel(IndicatorContent(state: .idle, elapsed: 0,
                                                        level: 0, previewTail: "", isNotch: false))
    private let hosting: NSHostingView<IndicatorRoot>
    private var visible = false
    private var isNotch = false
    private var notchBand: CGFloat = IndicatorMetrics.defaultNotchBand
    private var levels: [Float] = []
    /// True while the expand spring is animating; suppresses content re-application so per-tick
    /// updates don't force mid-animation re-renders (frame drops).
    private var expanding = false
    /// Armed here; the delay and its rationale live on `IndicatorMetrics.spinnerActivationDelay`.
    private var spinnerActive = false
    private var spinnerTimer: Timer?
    /// The accessibility settings the SwiftUI root was last built with, so we only rebuild it (a
    /// main-thread hitch) when they change — not on every show.
    private struct A11y: Equatable { let reduceMotion, increaseContrast, reduceTransparency: Bool }
    private var builtA11y: A11y?
    // Touched from the (nonisolated) deinit; removeObserver is safe to call from any thread.
    nonisolated(unsafe) private var screenObserver: NSObjectProtocol?

    public init() {
        hosting = NSHostingView(rootView: IndicatorRoot(model: model,
                                                        increaseContrast: false,
                                                        reduceMotion: false,
                                                        reduceTransparency: false))
        hosting.sizingOptions = []                              // AppKit owns the frame (ORA-IND-012)
        panel.contentView = hosting
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.repositionForScreenChange() }
        }
    }

    deinit { if let o = screenObserver { NotificationCenter.default.removeObserver(o) } }

    /// Show the indicator for a starting dictation; while already visible this is just a content
    /// update. Geometry is fixed at show time and NOT changed as text arrives (ORA-IND-012).
    /// Honors Reduce Motion: appear at final size, no expansion (ORA-IND-017).
    public func show(content: IndicatorContent) {
        guard !visible else { update(content); return }
        levels.removeAll(keepingCapacity: true)
        armSpinner(for: .idle)                     // fresh session starts as a flat waveform
        let metrics = NotchMetrics.forScreen(ActiveScreen.current())
        // Notch treatment only when the active screen is the built-in notched display (ORA-IND-015);
        // otherwise a pill (ORA-IND-014). Never fake a notch where none exists.
        adoptGeometry(of: metrics)
        // No shadow for the notch: a drop shadow would draw a visible bezel at the top edge where the
        // panel must merge seamlessly with the physical notch. The pill keeps its shadow to lift off
        // the wallpaper.
        panel.hasShadow = !isNotch
        // Rebuild the SwiftUI root ONLY when an accessibility setting changed — a full rebuild hitches
        // the main thread right as the expand animation starts, dropping frames. The model drives
        // content updates without a rebuild.
        let a11y = A11y(reduceMotion: reduceMotion, increaseContrast: increaseContrast,
                        reduceTransparency: reduceTransparency)
        if a11y != builtA11y {
            hosting.rootView = IndicatorRoot(model: model,
                                             increaseContrast: increaseContrast,
                                             reduceMotion: reduceMotion,
                                             reduceTransparency: reduceTransparency)
            builtA11y = a11y
        }
        position(on: metrics)
        apply(content)
        announceIfNeeded(for: content.state)

        panel.alphaValue = 1
        if reduceMotion {
            model.expanded = true                 // appear at final size, no motion (ORA-IND-017)
            panel.orderFrontRegardless()
        } else {
            model.expanded = false                // start collapsed (under the notch)…
            panel.orderFrontRegardless()
            // …then spring open on the next runloop turn so SwiftUI animates the change; `expanding`
            // suppresses per-tick content churn during the animation (see `update`).
            expanding = true
            DispatchQueue.main.async { [weak self] in self?.model.expanded = true }
            let settle = IndicatorMetrics.expandDuration + IndicatorMetrics.settleBuffer
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self else { return }
                self.expanding = false
                if self.visible { self.apply(self.model.content) }   // flush latest content once settled
            }
        }
        visible = true
    }

    /// Update content while visible (waveform level, elapsed, preview tail, state).
    private func update(_ content: IndicatorContent) {
        pushLevel(content.level)                   // keep accumulating levels…
        announceIfNeeded(for: content.state)
        armSpinner(for: content.state)
        // …but don't churn model.content mid-expand (see `expanding`); the post-animation flush in
        // `show` applies the latest content once settled.
        if expanding { return }
        apply(content)
    }

    public func hide() {
        guard visible else { return }
        visible = false
        lastAnnouncement = nil   // next session re-announces "Listening"
        armSpinner(for: .idle)   // disarm the delayed spinner so it can't carry into the next session
        // Clear the spinner state NOW (not after the collapse) so a fast re-show never catches a
        // leftover finalizing/inserting spinner — the next dictation always opens on the waveform.
        resetOrb()
        model.expanded = false
        if reduceMotion {
            panel.orderOut(nil)
        } else {
            // Remove the panel once the collapse has played (unless a show() re-armed it).
            let settle = IndicatorMetrics.collapseDuration + IndicatorMetrics.settleBuffer
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self, panel] in
                MainActor.assumeIsolated { if self?.visible != true { panel.orderOut(nil) } }
            }
        }
    }

    /// Reset the leading orb to non-spinning idle so the NEXT dictation starts as the waveform — no
    /// leftover spinner→waveform crossfade from the prior session's finalizing/inserting state (which
    /// the persistent model remembers). Routed through `apply()` to KEEP the current notch geometry so
    /// the panel collapses into the notch's shape, not the pill silhouette. No animation.
    private func resetOrb() {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            apply(IndicatorContent(state: .idle, elapsed: 0,
                                   level: 0, previewTail: "", isNotch: isNotch))
        }
    }

    // MARK: Rendering + geometry

    /// Push new content into the observable model (drives in-place animation).
    private func apply(_ content: IndicatorContent) {
        var c = content
        c.isNotch = isNotch
        c.notchBand = isNotch ? notchBand : 0
        c.levels = levels
        c.spinnerActive = spinnerActive
        model.content = c
    }

    /// Gate the leading-orb spinner behind `IndicatorMetrics.spinnerActivationDelay`: while
    /// finalizing/inserting, arm a one-shot timer that flips the spinner on only if still processing
    /// then; leaving that state disarms it.
    private func armSpinner(for state: SessionState) {
        let working = (state == .finalizing || state == .inserting)
        if working {
            guard !spinnerActive, spinnerTimer == nil else { return }
            spinnerTimer = Timer.scheduledTimer(withTimeInterval: IndicatorMetrics.spinnerActivationDelay,
                                                repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.visible else { return }
                    self.spinnerTimer = nil
                    self.spinnerActive = true
                    self.apply(self.model.content)   // re-apply so the orb morphs to the spinner
                }
            }
        } else {
            spinnerTimer?.invalidate(); spinnerTimer = nil
            spinnerActive = false
        }
    }

    private func pushLevel(_ level: Float) {
        levels.append(level)
        if levels.count > IndicatorMetrics.barCount { levels.removeFirst(levels.count - IndicatorMetrics.barCount) }
    }

    /// Record whether the active screen gets the notch or pill treatment, and the notch-band height.
    private func adoptGeometry(of metrics: NotchMetrics) {
        isNotch = metrics.hasNotch
        notchBand = metrics.notchHeight   // forScreen guarantees notchHeight > 0 when notched
    }

    private func position(on metrics: NotchMetrics) {
        let size = IndicatorMetrics.size(isNotch: isNotch, notchBand: notchBand)
        let frame = metrics.screenFrame
        let x = metrics.centerX - size.width / 2
        let y: CGFloat
        if isNotch {
            // Flush to the very top: the top band sits behind the opaque notch, the chin (with the
            // content) hangs below it (ORA-IND-011).
            y = frame.maxY - size.height
        } else {
            // Floating just beneath the menu bar (ORA-IND-014).
            y = frame.maxY - metrics.menuBarHeight - size.height - 4
        }
        panel.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: true)
    }

    private func repositionForScreenChange() {
        guard visible else { return }
        let metrics = NotchMetrics.forScreen(ActiveScreen.current())
        adoptGeometry(of: metrics)
        position(on: metrics)
        apply(model.content)
    }

    // MARK: VoiceOver announcements (SYS-3 / IND-3)

    /// The last spoken announcement — announcements fire on state CHANGES only, never on the
    /// per-tick level/elapsed updates that stream through `update(_:)`.
    private var lastAnnouncement: String?

    /// Announce dictation state transitions to VoiceOver. The panel is a non-activating decorative
    /// overlay VoiceOver never focuses, so state is surfaced as spoken announcements instead.
    private func announceIfNeeded(for state: SessionState) {
        let message: String?
        switch state {
        case .recording: message = "Listening"
        case .finalizing: message = "Transcribing"
        case .inserting: message = "Inserting text"
        case .idle: message = nil
        }
        guard let message, message != lastAnnouncement else { return }
        lastAnnouncement = message
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message,
                       .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: Accessibility settings (ORA-IND-017 / ORA-A11Y-001)

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    private var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
}
