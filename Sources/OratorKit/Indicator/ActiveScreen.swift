import AppKit
import CoreGraphics

/// Finds the screen the indicator should appear on: the one containing the frontmost app's key
/// window (ORA-IND-015). Falls back to the main screen when that can't be determined.
public enum ActiveScreen {
    public static func current() -> NSScreen {
        screenOfFrontmostWindow() ?? NSScreen.main ?? NSScreen.screens.first ?? NSScreen()
    }

    private static func screenOfFrontmostWindow() -> NSScreen? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let pid = app.processIdentifier
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        // First on-screen, layer-0 window owned by the frontmost app.
        for info in infoList {
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            return screenContaining(cgRect: bounds)
        }
        return nil
    }

    /// CGWindow bounds use a top-left origin anchored to the PRIMARY screen (Y grows down); NSScreen
    /// uses bottom-left. The flip constant is the primary screen's height (`screens[0]`, origin (0,0))
    /// — NOT the union of all screens, which breaks when a display sits above the built-in
    /// (E11 / ORA-IND-015).
    private static func screenContaining(cgRect: CGRect) -> NSScreen? {
        let center = CGPoint(x: cgRect.midX, y: cgRect.midY)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let flipped = CGPoint(x: center.x, y: primaryHeight - center.y)
        return NSScreen.screens.first { $0.frame.contains(flipped) }
    }
}
