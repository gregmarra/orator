import Foundation

/// What the text already in the target field implies about the dictation being appended to it.
///
/// Both decisions are pure functions of the characters before the caret, so the whole table is
/// testable without an accessibility element, a field, or a running app.
enum SentenceContext {

    /// Punctuation that ends a sentence, so the next word starts a new one.
    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    /// Punctuation that ends a *clause* — the next word continues the sentence and must NOT be
    /// capitalized. This is the case that was getting it wrong: after "hello," a follow-on dictation
    /// was being capitalized as though it began a new sentence.
    private static let continuers: Set<Character> = [",", ";", ":", "—", "–", "-"]
    /// Closing marks that may sit *after* a terminator ("she said 'go.'"), which we look through to
    /// find the punctuation that actually decides the case.
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "}", "”", "’"]

    /// Should the inserted text begin a new sentence (i.e. get a capital first letter)?
    ///
    /// True at the start of an empty field and after a sentence terminator or a line break; false
    /// mid-sentence — after a word, a comma, or any other clause punctuation. When the preceding text
    /// isn't readable the caller supplies nil and we assume a sentence start, which matches the
    /// standalone case (a fresh field, or text bound for the recovery menu).
    static func startsSentence(after preceding: String?) -> Bool {
        guard let preceding else { return true }
        // A trailing newline means a new line/paragraph, which always starts a sentence. Checked
        // before trimming, since trimming would discard exactly this evidence.
        if let last = preceding.last, last.isNewline { return true }
        var trimmed = Substring(preceding).drop { _ in false }
        while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
        // Look through closing quotes/brackets to the punctuation that actually decides.
        while let last = trimmed.last, closers.contains(last) { trimmed = trimmed.dropLast() }
        guard let last = trimmed.last else { return true }   // nothing but whitespace ⇒ empty field
        if terminators.contains(last) { return true }
        if continuers.contains(last) { return false }
        // A sentence is only in progress if the caret actually follows PROSE. Anything else — a shell
        // prompt ">", a "$" or "#", a box-drawing character — is interface chrome, and text typed
        // after it begins a sentence. Treating every unrecognized character as mid-sentence
        // suppressed the capital at a terminal prompt.
        return !(last.isLetter || last.isNumber)
    }

    /// A privacy-safe description of the character the decision turned on: its CLASS only, never the
    /// character itself, so dictated content cannot leak into the log (ORA-PRIV-002).
    static func describeLastCharacter(of preceding: String?) -> String {
        guard let preceding else { return "unreadable" }
        if let last = preceding.last, last.isNewline { return "newline" }
        var t = Substring(preceding)
        while let last = t.last, last.isWhitespace { t = t.dropLast() }
        while let last = t.last, closers.contains(last) { t = t.dropLast() }
        guard let last = t.last else { return "empty" }
        if terminators.contains(last) { return "terminator" }
        if continuers.contains(last) { return "clause-punctuation" }
        if last.isLetter || last.isNumber { return "word" }
        return "other"
    }

    /// Does the insertion need a separating space, because the caret sits immediately after a
    /// non-whitespace character (ORA-INS-008)? Back-to-back dictations into the same field would
    /// otherwise run together.
    static func needsLeadingSpace(after preceding: String?) -> Bool {
        guard let preceding, let last = preceding.last else { return false }
        return !last.isWhitespace
    }
}
