import Foundation

/// The live preview as the best text available at each moment: the accurate transcriber's confirmed
/// text, then only the preview transcriber's words past the point that text has reached. The accurate
/// model finalizes in ~3.8 s chunks; the preview model updates every ~250 ms but is less accurate, so
/// earlier words are upgraded to the accurate wording as soon as it exists, at no extra latency.
///
/// Aligned by words, not audio time: the progressive DictationTranscriber gives one time range per
/// result, not per word, and restates the whole utterance, so a time cut duplicated whole sentences.
/// Measured 2026-10-29 on 4 synthesized passages (206 snapshots): mean error of the displayed preview
/// against the final text 0.124 preview-only → 0.097 spliced, never worse on any passage.
/// Display only — nothing here reaches inserted text.
enum PreviewSplice {
    /// Confirmed words matched against the preview: enough to place the seam, small enough that a
    /// long dictation's alignment stays cheap (window × preview words per update).
    static let window = 40

    static func compose(confirmed: String, preview: String) -> String {
        let after = wordsAfter(confirmed: confirmed, preview: preview.split(whereSeparator: \.isWhitespace).map(String.init))
        return [confirmed.trimmingCharacters(in: .whitespaces), after.joined(separator: " ")]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The preview words after the end of its best word-level alignment with the confirmed text.
    static func wordsAfter(confirmed: String, preview: [String]) -> ArraySlice<String> {
        let all = normalized(confirmed.split(whereSeparator: \.isWhitespace).map(String.init))
        guard !all.isEmpty else { return preview[...] }
        let a = Array(all.suffix(window))
        let f = normalized(preview)
        guard !f.isEmpty else { return [] }
        // Edit distance of a against a slice of f ending at j. The whole confirmed text must align
        // from the preview's start; a suffix window may start anywhere.
        let freeStart = a.count < all.count
        var prev = freeStart ? Array(repeating: 0, count: f.count + 1) : Array(0...f.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: f.count)
            for j in 1...f.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == f[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        // Lowest cost; on a tie the LATEST end, so a repeated phrase never re-shows covered words.
        var end = 0
        for j in prev.indices where prev[j] <= prev[end] { end = j }
        return preview[end...]
    }

    /// Lowercased letters and digits only, so "home." matches "home" and "Friday" matches "friday".
    private static func normalized(_ words: [String]) -> [String] {
        words.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
    }
}
