import Foundation

/// The shape of one insertion, for the always-on `Insert shape:` log line: which host and element
/// the caret-context decisions were made from, what they decided, and whether the paste verified.
///
/// Deliberately content-free. The only fragment of the host field it carries is the single character
/// before the caret — enough to explain a spacing or casing decision, never enough to reconstruct
/// text — and the only fragment of the window title is the product-name tail after the last " - ".
/// That is what makes it safe to leave on and read back weeks later.
struct InsertShape: CustomStringConvertible {
    enum ContextSource: String {
        case none           // the field would not tell us anything
        case caretAtStart   // caret offset 0 ⇒ empty context, no read needed
        case range          // AXStringForRange window before the caret
        case valueSlice     // kAXValue sliced at the caret offset
        case wholeValue     // no caret offset ⇒ the whole kAXValue
    }
    enum Verification: String {
        case unverifiable   // the field's value was unreadable, so nothing could be observed
        case landed         // the value changed after ⌘V
        case rejected       // the value was readable and did NOT change
    }

    var build: String?
    var app: String?
    var windowTitleTail: String?
    var role: String?
    var subrole: String?
    var domID: String?
    var contextSource: ContextSource
    var contextLength: Int?
    var lastCharacter: Character?
    var leadingSpace: Bool
    var startsSentence: Bool
    var valueLengthBefore: Int?
    var verification: Verification = .unverifiable

    /// The last two " - " segments of a window title, capped so a title with no separator can't
    /// smuggle a whole document name into the log. Two, not one: Chrome appends the profile name as
    /// its own segment ("… - Google Docs - Greg"), so the last segment alone lost the product name.
    static func titleTail(of title: String) -> String {
        let tail = title.components(separatedBy: " - ").suffix(2).joined(separator: " - ")
        return String(tail.prefix(40))
    }

    var description: String {
        let last = lastCharacter.map { String(reflecting: String($0)) } ?? "nil"
        return [
            "build=\(build ?? "nil")",
            "app=\(app ?? "nil")",
            "win=\(windowTitleTail.map { "\"\($0)\"" } ?? "nil")",
            "role=\(role ?? "nil")",
            "subrole=\(subrole ?? "nil")",
            "dom=\(domID ?? "nil")",
            "ctx=\(contextSource.rawValue)",
            "ctxLen=\(contextLength.map(String.init) ?? "nil")",
            "last=\(last)",
            "space=\(leadingSpace)",
            "sentence=\(startsSentence)",
            "preLen=\(valueLengthBefore.map(String.init) ?? "nil")",
            "verify=\(verification.rawValue)",
        ].joined(separator: " ")
    }
}
