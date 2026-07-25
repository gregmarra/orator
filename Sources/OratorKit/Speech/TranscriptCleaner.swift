import Foundation

/// Post-processes a finalized transcript before insertion (ORA-ASR-007). The `SpeechTranscriber`
/// renders the opening pause/breath of a fresh utterance as stray leading punctuation ("..", ",...",
/// "…") and fails to capitalize the first real word; trim that leading junk and apply sentence-start
/// capitalization. Internal punctuation and casing (which the model gets right) are left untouched.
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
    ///
    /// Note the asymmetry: we only ever capitalize, never lower-case. The model already casts proper
    /// nouns correctly, so leaving its casing alone mid-sentence keeps "Michael" while still writing
    /// "the" — whereas forcing lower-case would corrupt every name.
    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }
}
