import Foundation

/// Post-processes a finalized transcript before insertion (ORA-ASR-007). The `SpeechTranscriber`
/// renders the opening pause/breath of a fresh utterance as stray leading punctuation ("..", ",...",
/// "…") and fails to capitalize the first real word; trim that leading junk and apply sentence-start
/// capitalization. Internal punctuation and casing (which the model gets right) are left untouched.
enum TranscriptCleaner {
    /// Punctuation the recognizer spuriously emits for a leading silence. Quotes, brackets, numbers,
    /// and currency are intentionally NOT stripped — only sentence-delimiter punctuation.
    private static let leadingJunk: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "·"]

    static func clean(_ text: String) -> String {
        // Drop any leading run of whitespace and stray sentence punctuation.
        let s = text.drop { $0.isWhitespace || leadingJunk.contains($0) }
        let result = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
        // Sentence-start capitalization (uppercased() is a no-op on already-upper/non-cased first chars).
        return result.prefix(1).uppercased() + result.dropFirst()
    }
}
