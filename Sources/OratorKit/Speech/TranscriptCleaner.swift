import Foundation
import NaturalLanguage

/// Post-processes a finalized transcript before insertion (ORA-ASR-007). The recognizer renders the
/// opening pause/breath of a fresh utterance as stray leading punctuation ("..", ",...", "…"), which
/// is trimmed here. Casing of the first word is decided later, by the insertion step, from what
/// actually precedes the caret: every utterance looks like a new sentence to the recognizer, so the
/// leading capital it produces is right only when the dictation really does start one. Internal
/// punctuation and casing (which the model gets right) are left untouched.
enum TranscriptCleaner {
    /// Punctuation the recognizer spuriously emits for a leading silence. Quotes, brackets, numbers,
    /// and currency are intentionally NOT stripped — only sentence-delimiter punctuation.
    private static let leadingJunk: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "·"]

    /// Strip the recognizer's leading junk. Deliberately does NOT change case: whether the first word
    /// begins a sentence depends on what is already in the target field, which only the insertion step
    /// knows (see `SentenceContext`). Capitalizing here made every follow-on dictation start with a
    /// capital even when it continued a sentence after a comma or a space.
    static func clean(_ text: String) -> String {
        // Drop any leading run of whitespace and stray sentence punctuation.
        let s = text.drop { $0.isWhitespace || leadingJunk.contains($0) }
        return String(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Apply sentence-start capitalization. `uppercased()` is a no-op on an already-capital or
    /// non-cased first character, so this is safe to apply unconditionally where a sentence starts.
    /// The mirror of `continuing(_:)`, which undoes a capital where the sentence carries on.
    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    /// Parts of speech that are safe to lower-case when continuing a sentence. Everything a proper
    /// noun could be — Noun above all — is deliberately absent, so a continuation that begins with a
    /// name keeps its capital.
    ///
    /// Grammatical class, not a word list: a list would be arbitrary, forever incomplete, and English
    /// only, while `NLTagger` covers every language the recognizer does. Name detection alone is not
    /// enough — it correctly flags "Michael" and "Google" but misses "Apple", "Orator" and "Tuesday",
    /// all of which come back as plain nouns; keying on the class catches those too.
    private static let lowercasableClasses: Set<NLTag> = [
        .verb, .adverb, .conjunction, .determiner, .preposition, .interjection, .pronoun, .particle,
    ]

    /// Undo the recognizer's utterance-start capital when this text continues an existing sentence.
    ///
    /// The recognizer capitalizes the first word of EVERY utterance — each dictation looks like a
    /// fresh sentence to it — so continuing after a comma yields "Let's" where "let's" is wanted.
    /// Declining to capitalize is not enough; the capital has to be undone.
    ///
    /// Conservative by design: anything that might be a name is left exactly as recognized. A stray
    /// capital is a far smaller error than a mangled name.
    static func continuing(_ text: String, locale: Locale = .current) -> String {
        guard let first = text.first, first.isUppercase else { return text }
        // "I" is a pronoun, and so lower-caseable by class, but is always capitalized in English.
        let bareWord = text.prefix { !$0.isWhitespace }.filter { $0.isLetter }
        if bareWord == "I" { return text }

        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        if let code = locale.language.languageCode?.identifier {
            tagger.setLanguage(NLLanguage(code), range: text.startIndex..<text.endIndex)
        }
        let (tag, _) = tagger.tag(at: text.startIndex, unit: .word, scheme: .lexicalClass)
        guard let tag, lowercasableClasses.contains(tag) else { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }
}
