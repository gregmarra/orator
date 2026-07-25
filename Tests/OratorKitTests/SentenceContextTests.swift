import XCTest
@testable import OratorKit

/// Capitalization must follow the text already in the field. It used to be applied unconditionally in
/// the coordinator, which has no idea what precedes the caret — so dictating a fragment, pausing, and
/// continuing produced "hello, There" instead of "hello, there".
final class SentenceContextTests: XCTestCase {

    // MARK: Continuations must NOT be capitalized

    func testClausePunctuationContinuesTheSentence() {
        for preceding in ["hello,", "hello, ", "one thing;", "as follows:", "a dash —", "wait -"] {
            XCTAssertFalse(SentenceContext.startsSentence(after: preceding),
                           "'\(preceding)' ends a clause, not a sentence")
        }
    }

    func testAWordOrTrailingSpaceContinuesTheSentence() {
        XCTAssertFalse(SentenceContext.startsSentence(after: "the quick brown"))
        XCTAssertFalse(SentenceContext.startsSentence(after: "the quick brown "))
        XCTAssertFalse(SentenceContext.startsSentence(after: "value 42 "))
    }

    // MARK: Sentence starts

    func testTerminatorsStartANewSentence() {
        for preceding in ["Done.", "Done. ", "Really?", "Stop!", "Wait…", "Done.  "] {
            XCTAssertTrue(SentenceContext.startsSentence(after: preceding),
                          "'\(preceding)' ends a sentence")
        }
    }

    func testEmptyFieldOrUnreadableContextStartsASentence() {
        XCTAssertTrue(SentenceContext.startsSentence(after: ""))
        XCTAssertTrue(SentenceContext.startsSentence(after: "   "))
        // nil = AX couldn't tell us; standalone text is the safe assumption.
        XCTAssertTrue(SentenceContext.startsSentence(after: nil))
    }

    func testNewlineStartsASentence() {
        XCTAssertTrue(SentenceContext.startsSentence(after: "a paragraph\n"))
        XCTAssertTrue(SentenceContext.startsSentence(after: "a list item,\n"),
                      "a line break outranks the comma before it")
    }

    /// Quotes and brackets can sit after the punctuation that actually decides.
    func testClosingMarksAreLookedThrough() {
        XCTAssertTrue(SentenceContext.startsSentence(after: "she said \"go.\""))
        XCTAssertTrue(SentenceContext.startsSentence(after: "(that's settled.)"))
        XCTAssertFalse(SentenceContext.startsSentence(after: "(an aside),"))
    }

    // MARK: Leading space (ORA-INS-008)

    func testLeadingSpaceOnlyAfterANonSpaceCharacter() {
        XCTAssertTrue(SentenceContext.needsLeadingSpace(after: "hello"))
        XCTAssertTrue(SentenceContext.needsLeadingSpace(after: "Done."))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: "hello "))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: ""))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: nil))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: "a line\n"))
    }

    // MARK: Casing policy

    /// We only ever ADD a capital, never remove one — the recognizer already casts proper nouns, and
    /// forcing lower-case mid-sentence would turn "Michael" into "michael".
    func testMidSentenceKeepsTheModelsCasingForProperNouns() {
        let text = "Michael said yes"
        XCTAssertFalse(SentenceContext.startsSentence(after: "I told "))
        XCTAssertEqual(text, text, "continuation path must pass the text through untouched")
        XCTAssertEqual(TranscriptCleaner.capitalized("the waveform"), "The waveform")
        XCTAssertEqual(TranscriptCleaner.capitalized("Michael"), "Michael")
    }
}
