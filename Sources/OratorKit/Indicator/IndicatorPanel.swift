import AppKit

/// The floating indicator window: a borderless, non-activating panel that never becomes key
/// (ORA-IND-016) — taking key focus would break insertion into the target field. Joins all Spaces,
/// floats over full-screen apps, sits above the menu-bar level.
public final class IndicatorPanel: NSPanel {
    public init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Never take focus from the target field.
        isExcludedFromWindowsMenu = true
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}
