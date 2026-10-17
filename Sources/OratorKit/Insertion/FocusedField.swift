import ApplicationServices

/// The focused text field, reduced to the four reads insertion makes of it.
///
/// Every answer is optional because every one can be refused: hosts withhold `kAXValue`, skip
/// `AXStringForRange`, or report no caret. Putting the reads behind a protocol is what lets
/// `TextInserter`'s decisions — which read to trust, how to slice, what counts as rejected — be
/// table-tested without a live accessibility element.
protocol FocusedField {
    /// `kAXSubrole` — consulted only for the secure-field check (ORA-INS-007).
    var subrole: String? { get }
    /// Caret offset (UTF-16) within the field, if it reports one.
    var caretLocation: Int? { get }
    /// `AXStringForRange` — the parameterized read that works where `kAXValue` is refused.
    func string(forRange location: Int, length: Int) -> String?
    /// `kAXValue` — the whole text, when the host will hand it over.
    var value: String? { get }
}

/// The live implementation: one resolved `AXUIElement`. Each read is a cross-process call with real
/// main-thread cost, so callers resolve the element once and reuse this for every check.
struct AXFocusedField: FocusedField {
    let element: AXUIElement

    /// The system-wide focused element, or nil when the host publishes no accessibility tree (E16).
    static func current() -> AXFocusedField? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID()
        else { return nil }
        return AXFocusedField(element: element as! AXUIElement)   // guarded by the type-id check above
    }

    var subrole: String? { copyString(kAXSubroleAttribute) }

    var value: String? { copyString(kAXValueAttribute) }

    var caretLocation: Int? {
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let axRange = rangeRef, CFGetTypeID(axRange) == AXValueGetTypeID() else { return nil }
        var caret = CFRange()
        guard AXValueGetValue((axRange as! AXValue), .cfRange, &caret), caret.location >= 0 else { return nil }
        return caret.location
    }

    func string(forRange location: Int, length: Int) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
                element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success
        else { return nil }
        return result as? String
    }

    private func copyString(_ attr: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
