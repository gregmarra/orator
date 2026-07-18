import AppKit

/// Notch geometry derived **dynamically** from the platform (ORA-IND-013 / §11.3) so the app works on
/// any Mac; hardcoded per-model constants are a labelled last-resort fallback. Recomputed on screen
/// changes by the controller (ORA-IND-015).
///
/// **The physical notch is opaque hardware** — the camera housing — so nothing can be drawn *in* it.
/// These metrics let the indicator size its top "notch band" to the real notch and place all content
/// **below** it, in lit screen area (ORA-IND-011).
public struct NotchMetrics: Equatable, Sendable {
    public let hasNotch: Bool
    /// Physical notch height (points) == `safeAreaInsets.top`. Content must sit below this.
    public let notchHeight: CGFloat
    /// Screen-space X of the notch centre (== screen horizontal centre).
    public let centerX: CGFloat
    /// Menu-bar height (top inset) — the indicator anchors at the menu-bar top.
    public let menuBarHeight: CGFloat
    /// Full screen frame (for positioning the panel).
    public let screenFrame: CGRect

    // Last-resort fallbacks if the platform doesn't report auxiliary areas (ORA-IND-013). Real
    // measured values: 14-inch 185×32 pt, 16-inch 220×38 pt.
    static let fallback14Height: CGFloat = 32
    static let fallback16Height: CGFloat = 38

    public static func forScreen(_ screen: NSScreen) -> NotchMetrics {
        let insets = screen.safeAreaInsets
        let frame = screen.frame
        let menuBar = max(insets.top, NSStatusBar.system.thickness)

        // No top safe-area inset ⇒ not notched.
        guard insets.top > 0 else {
            return NotchMetrics(hasNotch: false, notchHeight: 0,
                                centerX: frame.midX, menuBarHeight: menuBar, screenFrame: frame)
        }
        // Notched. Prefer the measured notch height when the auxiliary areas leave a gap (article-
        // documented: the gap equals right.minX − left.maxX for full-width bars); otherwise infer a
        // plausible physical notch from the display width.
        let notchHeight: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
           frame.width - left.width - right.width > 0 {
            notchHeight = insets.top
        } else {
            let fallbackHeight = frame.width >= 1600 ? Self.fallback16Height : Self.fallback14Height
            notchHeight = max(insets.top, fallbackHeight)
        }
        return NotchMetrics(hasNotch: true, notchHeight: notchHeight,
                            centerX: frame.midX, menuBarHeight: menuBar, screenFrame: frame)
    }
}
