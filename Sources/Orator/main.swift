import AppKit
import OratorKit

// AppKit lifecycle entry point (§11.1). LSUIElement + .accessory ⇒ menu-bar agent, no Dock icon.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
