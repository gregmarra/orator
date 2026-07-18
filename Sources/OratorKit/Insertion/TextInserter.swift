import AppKit
import ApplicationServices
import CoreGraphics
import Carbon

/// Identity of the app/field that had focus when recording started (ORA-INS-002 / §11.6).
public struct TargetContext: Sendable {
    public let pid: pid_t
    public let bundleID: String?

    /// Snapshot the frontmost application at record-start.
    @MainActor
    public static func capture() -> TargetContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return TargetContext(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }
}

/// What happened when we tried to place text.
public enum InsertionOutcome: Sendable, Equatable {
    case inserted                       // placed into the target field
    case deferredToRecovery(RecoveryReason)  // could not — route to recovery buffer (no text lost)
}

/// Places finalized text into the target field, once, as a single unit (ORA-INS-001).
///
/// Paste-only: AX only locates the focused element, detects secure fields, and confirms the
/// frontmost app; text is placed via the concealed pasteboard + synthetic ⌘V (ORA-INS-003/004/005).
/// One path across AppKit, browser, web-view (Chromium) apps, and most terminals; participates in
/// the host app's undo.
@MainActor
public final class TextInserter {
    /// Per-app settle delay before/after paste for hosts with restrictive input handling
    /// (ORA-INS-006). A minimal built-in lookup, NOT a user-facing config surface.
    private static let settleDelays: [String: Duration] = [
        "com.apple.Terminal": .milliseconds(30),
        "com.googlecode.iterm2": .milliseconds(40),
        "com.github.wez.wezterm": .milliseconds(40),
    ]

    public init() {}

    /// Attempt insertion. `text` is guaranteed non-empty by the caller.
    public func insert(_ text: String, into target: TargetContext,
                       accessibilityGranted: Bool) async -> InsertionOutcome {
        // 1. Confirm the frontmost app still matches the record-start target (ORA-INS-002 / E8).
        guard let current = NSWorkspace.shared.frontmostApplication else {
            return .deferredToRecovery(.noTarget)
        }
        guard current.processIdentifier == target.pid else {
            return .deferredToRecovery(.focusChanged)
        }

        // 2. Inspect the focused element (needs Accessibility). Without it we cannot verify the
        //    target is safe/editable, so route to recovery (E2) rather than risk a wrong paste.
        guard accessibilityGranted else {
            return .deferredToRecovery(.accessibilityMissing)
        }
        // Resolve the focused element ONCE and reuse it for every check + the paste verification —
        // each `AXUIElementCopyAttributeValue` is a cross-process call with real main-thread cost.
        guard let element = focusedElement() else {
            return .deferredToRecovery(.noTarget)
        }
        if isSecureField(element) {
            return .deferredToRecovery(.secureField)          // ORA-INS-007 / E9
        }

        // 3. Paste path with full pasteboard discipline (ORA-INS-005). Prepend a separating space when
        //    the caret sits immediately after a word character, so back-to-back dictations into the
        //    same field don't run together (ORA-INS-008).
        let delay = target.bundleID.flatMap { Self.settleDelays[$0] }
        let toInsert = needsLeadingSpace(element) ? " " + text : text
        return await paste(toInsert, settle: delay, element: element)
    }

    /// Best-effort: true when the caret sits right after a non-whitespace character (so a new
    /// dictation needs a separating space). Reads value + caret offset via AX; false when either
    /// isn't readable — the safe default for fields that don't expose these attributes.
    private func needsLeadingSpace(_ element: AXUIElement) -> Bool {
        guard let text = copyString(element, kAXValueAttribute), !text.isEmpty else { return false }
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axRange = rangeRef, CFGetTypeID(axRange) == AXValueGetTypeID() else { return false }
        var caret = CFRange()
        guard AXValueGetValue((axRange as! AXValue), .cfRange, &caret), caret.location > 0 else { return false }
        let units = Array(text.utf16)
        let i = caret.location - 1   // guarded by caret.location > 0 above, so i >= 0
        guard i < units.count, let scalar = Unicode.Scalar(units[i]) else { return false }
        return !CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    // MARK: Focused-field inspection

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return (element as! AXUIElement)   // guarded by the type-id check above
    }

    /// A secure field (password) or globally-active secure input refuses programmatic paste. Anything
    /// else focused is treated as editable: paste is the real test (browser/web-view fields often don't
    /// advertise settable AX attributes yet still accept ⌘V), and the recovery buffer is the safety net
    /// if it lands nowhere (M4).
    private func isSecureField(_ axElement: AXUIElement) -> Bool {
        // True when the focused field advertises the AXSecureTextField subrole, or when secure input is
        // engaged globally (e.g. a password prompt open elsewhere, E10). Both refuse programmatic paste.
        copyString(axElement, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || SecureInput.isGloballyActive
    }

    private func copyString(_ element: AXUIElement, _ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }

    // MARK: Paste

    private func paste(_ text: String, settle: Duration?, element: AXUIElement) async -> InsertionOutcome {
        let preLength = valueLength(of: element)      // for best-effort verification
        let snapshot = Pasteboard.snapshot()
        let ourChangeCount = Pasteboard.writeConcealed(text)

        if let settle { try? await Task.sleep(for: settle) }
        postCommandV()

        // Completion cue fires immediately (caller); restore must not block it (ORA-INS-005).
        // Restore only AFTER the paste lands (focused field's value grew), or after a conservative
        // safety delay if the value is unreadable — always guarded by changeCount so a fresh user
        // copy is never clobbered (E13). Avoids the "restore beats a slow host that then pastes the
        // old clipboard" wrong-text hazard.
        Task { @MainActor in
            let landed = await self.awaitPasteConsumed(preLength: preLength, element: element)
            if !landed { try? await Task.sleep(for: .milliseconds(500)) }   // extra safety if unconfirmed
            Pasteboard.restore(snapshot, ifUnchangedFrom: ourChangeCount)
        }
        return .inserted
    }

    /// Length of the element's text value, if readable via AX (nil when unavailable).
    private func valueLength(of element: AXUIElement) -> Int? {
        copyString(element, kAXValueAttribute)?.count
    }

    /// Poll (bounded) for the focused field's value to grow, confirming the paste landed.
    private func awaitPasteConsumed(preLength: Int?, element: AXUIElement) async -> Bool {
        guard let preLength else { return false }     // not verifiable ⇒ caller uses the safety delay
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(800))
        while ContinuousClock.now < deadline {
            if let now = valueLength(of: element), now > preLength { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }

    /// Resolve the key code that types "v" in the **current** keyboard layout, so a synthesized ⌘V
    /// lands as Paste on non-QWERTY layouts (Dvorak, AZERTY, …). Falls back to the ANSI-V physical
    /// key code, so the worst case matches a fixed key code (ORA-INS-004).
    static func pasteKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let layoutPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(layoutPtr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> CGKeyCode in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            for code in 0..<128 {
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0,
                                           UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                           &deadKeys, chars.count, &length, &chars)
                guard status == noErr, length == 1, let scalar = Unicode.Scalar(UInt32(chars[0])) else { continue }
                if scalar == "v" { return CGKeyCode(code) }
            }
            return fallback
        }
    }

    /// Synthesize ⌘V using the layout-aware paste key code (ORA-INS-004). Posted to the HID tap so
    /// the frontmost app receives it as a real paste.
    private func postCommandV() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let v = Self.pasteKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
