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

    /// An unknown context must fabricate nothing: no space, and the safe capital. This is the state
    /// a terminal lands in, where the accessibility buffer is scrollback rather than the typed line.
    func testUnknownContextAddsNoSpaceAndCapitalizes() {
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: nil))
        XCTAssertTrue(SentenceContext.startsSentence(after: nil))
    }

    func testLeadingSpaceOnlyAfterANonSpaceCharacter() {
        XCTAssertTrue(SentenceContext.needsLeadingSpace(after: "hello"))
        XCTAssertTrue(SentenceContext.needsLeadingSpace(after: "Done."))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: "hello "))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: ""))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: nil))
        XCTAssertFalse(SentenceContext.needsLeadingSpace(after: "a line\n"))
    }

    // MARK: Casing policy

    /// The recognizer capitalizes the first word of EVERY utterance, so a continuation arrives as
    /// "Let's see" when "let's see" is wanted — declining to capitalize is not enough, it has to be
    /// undone. Restricted to function words so a name can never be corrupted.
    func testContinuationLowersOnlySafeLeadingWords() {
        XCTAssertEqual(TranscriptCleaner.continuing("Let's see what happens"), "let's see what happens")
        XCTAssertEqual(TranscriptCleaner.continuing("No, it's still capitalizing"), "no, it's still capitalizing")
        XCTAssertEqual(TranscriptCleaner.continuing("And then we left"), "and then we left")
        XCTAssertEqual(TranscriptCleaner.continuing("The waveform moved"), "the waveform moved")
    }

    /// The case this restraint exists for: a continuation can legitimately begin with a name.
    func testContinuationNeverLowersAProperNoun() {
        XCTAssertEqual(TranscriptCleaner.continuing("Michael said yes"), "Michael said yes")
        XCTAssertEqual(TranscriptCleaner.continuing("Priya and I disagreed"), "Priya and I disagreed")
        // Name detection alone MISSES these — they come back as plain nouns — so the rule keys on
        // lexical class, which protects them anyway.
        XCTAssertEqual(TranscriptCleaner.continuing("Orator is working"), "Orator is working")
        XCTAssertEqual(TranscriptCleaner.continuing("Apple released it"), "Apple released it")
        XCTAssertEqual(TranscriptCleaner.continuing("Tuesday works for me"), "Tuesday works for me")
        XCTAssertEqual(TranscriptCleaner.continuing("Google that for me"), "Google that for me")
        XCTAssertEqual(TranscriptCleaner.continuing("I think so"), "I think so",
                       "'I' is a pronoun, but is always capitalized in English")
    }

    func testContinuationLeavesAlreadyLowercaseTextAlone() {
        XCTAssertEqual(TranscriptCleaner.continuing("the waveform moved"), "the waveform moved")
        XCTAssertEqual(TranscriptCleaner.continuing(""), "")
    }

    func testCapitalizationAtASentenceStartIsUnchanged() {
        XCTAssertEqual(TranscriptCleaner.capitalized("the waveform"), "The waveform")
        XCTAssertEqual(TranscriptCleaner.capitalized("Michael"), "Michael")
    }
}
