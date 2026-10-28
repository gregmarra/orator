import XCTest
import ApplicationServices
@testable import OratorKit

/// A focused field that answers (or refuses) each read exactly as scripted, and records what it was
/// asked — so the tests can see WHICH read `precedingText` trusted, not just what came back.
private final class FakeField: FocusedField {
    var subrole: String?
    var caretLocation: Int?
    var value: String?
    /// nil = the host refuses `AXStringForRange`. Otherwise sliced out of `rangeSource` by UTF-16 offset.
    var rangeSource: String?
    private(set) var rangeRequests: [(location: Int, length: Int)] = []

    init(subrole: String? = nil, caret: Int? = nil, value: String? = nil, rangeSource: String? = nil) {
        self.subrole = subrole
        self.caretLocation = caret
        self.value = value
        self.rangeSource = rangeSource
    }

    func string(forRange location: Int, length: Int) -> String? {
        rangeRequests.append((location, length))
        guard let rangeSource else { return nil }
        let units = Array(rangeSource.utf16)
        let end = min(location + length, units.count)
        return String(decoding: units[min(location, end)..<end], as: UTF16.self)
    }
}

/// The rules in `TextInserter` that decide what text lands and whether a dictation counts as
/// inserted or goes to recovery — each learned from a real host, none observable without a fake field.
final class TextInserterDecisionTests: XCTestCase {

    // MARK: precedingText — which read to trust

    /// WhatsApp refuses `kAXValue` but answers `AXStringForRange`; the range read must come first.
    func testRangeReadIsPreferredOverTheValue() {
        let field = FakeField(caret: 5, value: "WRONG", rangeSource: "hello world")
        XCTAssertEqual(TextInserter.precedingText(field), "hello")
        XCTAssertEqual(field.rangeRequests.count, 1)
        XCTAssertEqual(field.rangeRequests.first?.location, 0)
        XCTAssertEqual(field.rangeRequests.first?.length, 5)
    }

    func testRangeReadAsksOnlyForTheContextWindow() {
        let long = String(repeating: "a", count: 200)
        let field = FakeField(caret: 200, rangeSource: long)
        XCTAssertEqual(TextInserter.precedingText(field)?.utf16.count, TextInserter.contextWindow)
        XCTAssertEqual(field.rangeRequests.first?.location, 200 - TextInserter.contextWindow)
        XCTAssertEqual(field.rangeRequests.first?.length, TextInserter.contextWindow)
    }

    func testRangeRefusedFallsBackToSlicingTheValue() {
        let field = FakeField(caret: 5, value: "hello world")
        XCTAssertEqual(TextInserter.precedingText(field), "hello")
    }

    /// A stale caret can sit past the end of the value; the slice is clamped, not a crash.
    func testStaleCaretPastTheEndOfTheValueIsClamped() {
        let field = FakeField(caret: 50, value: "short")
        XCTAssertEqual(TextInserter.precedingText(field), "short")
    }

    /// The value fallback slices the WHOLE prefix, not just the context window.
    func testValueFallbackIsNotLimitedToTheWindow() {
        let long = String(repeating: "b", count: 100)
        let field = FakeField(caret: 100, value: long)
        XCTAssertEqual(TextInserter.precedingText(field), long)
    }

    func testNoCaretFallsBackToTheWholeValue() {
        XCTAssertEqual(TextInserter.precedingText(FakeField(value: "all of it")), "all of it")
        XCTAssertNil(TextInserter.precedingText(FakeField()))
    }

    func testNothingAnswersMeansUnreadable() {
        XCTAssertNil(TextInserter.precedingText(FakeField(caret: 5)))
    }

    func testCaretAtTheStartIsAnEmptyContextWithoutAnyRead() {
        let field = FakeField(caret: 0, value: "after the caret", rangeSource: "after the caret")
        XCTAssertEqual(TextInserter.precedingText(field), "")
        XCTAssertTrue(field.rangeRequests.isEmpty)
    }

    /// No focused element at all (Steam / E16) ⇒ unreadable, which callers treat as standalone text.
    func testNilFieldIsUnreadable() {
        XCTAssertNil(TextInserter.precedingText(nil))
    }

    /// AX offsets are UTF-16: "👋" is two code units, so a caret at 3 sits after "👋 ".
    func testValueSliceUsesUTF16Offsets() {
        let field = FakeField(caret: 3, value: "👋 there")
        XCTAssertEqual(TextInserter.precedingText(field), "👋 ")
    }

    func testRangeReadUsesUTF16Offsets() {
        let text = "hi 👋"                                  // 3 + 2 UTF-16 units
        let field = FakeField(caret: text.utf16.count, rangeSource: text + " more")
        XCTAssertEqual(TextInserter.precedingText(field), text)
        XCTAssertEqual(field.rangeRequests.first?.length, 5)
    }

    // MARK: compose — case and spacing from the preceding text

    func testComposeTable() {
        let cases: [(preceding: String?, expected: TextInserter.Composition)] = [
            (nil, .init(text: "The waveform", leadingSpace: false, startsSentence: true)),
            ("", .init(text: "The waveform", leadingSpace: false, startsSentence: true)),
            ("Done.", .init(text: " The waveform", leadingSpace: true, startsSentence: true)),
            ("Done. ", .init(text: "The waveform", leadingSpace: false, startsSentence: true)),
            ("hello,", .init(text: " the waveform", leadingSpace: true, startsSentence: false)),
            ("hello ", .init(text: "the waveform", leadingSpace: false, startsSentence: false)),
            ("a line\n", .init(text: "The waveform", leadingSpace: false, startsSentence: true)),
            ("\u{200B}", .init(text: "The waveform", leadingSpace: false, startsSentence: true)),
        ]
        for c in cases {
            XCTAssertEqual(TextInserter.compose("The waveform", after: c.preceding), c.expected,
                           "after \(String(describing: c.preceding))")
        }
    }

    /// A continuation never lowers a name.
    func testComposeKeepsAProperNounMidSentence() {
        XCTAssertEqual(TextInserter.compose("Michael said yes", after: "and then").text, " Michael said yes")
    }

    // MARK: isSecureField

    func testSecureFieldDetection() {
        let secure = FakeField(subrole: kAXSecureTextFieldSubrole as String)
        let plain = FakeField(subrole: "AXSearchField")
        XCTAssertTrue(TextInserter.isSecureField(secure, globallySecure: false))
        XCTAssertFalse(TextInserter.isSecureField(plain, globallySecure: false))
        XCTAssertTrue(TextInserter.isSecureField(plain, globallySecure: true))
        // No field (E16): global secure input is the only surviving veto.
        XCTAssertFalse(TextInserter.isSecureField(nil, globallySecure: false))
        XCTAssertTrue(TextInserter.isSecureField(nil, globallySecure: true))
    }

    // MARK: pasteOutcome — success vs recovery

    func testPasteOutcomeTable() {
        let cases: [(preValue: String?, landed: Bool, expected: InsertionOutcome)] = [
            ("before", true, .inserted),                            // value changed: landed
            ("before", false, .deferredToRecovery(.pasteRejected)), // readable, unchanged: rejected (E15)
            ("", false, .deferredToRecovery(.pasteRejected)),       // an empty value is still readable
            (nil, false, .inserted),                                // unreadable (Chromium): unverifiable
            (nil, true, .inserted),
        ]
        for c in cases {
            XCTAssertEqual(TextInserter.pasteOutcome(preValue: c.preValue, landed: c.landed), c.expected,
                           "preValue \(String(describing: c.preValue)), landed \(c.landed)")
        }
    }

    /// Google Docs' focused element is a 2-character run of invisible characters that never changes:
    /// unverifiable, so a paste that landed doesn't raise "Paste didn't land".
    func testInvisibleStandInFieldIsUnverifiable() {
        let docs = FakeField(caret: 1, value: "\u{200B}\u{200B}")
        XCTAssertNil(TextInserter.verifiableValue(docs))
        XCTAssertEqual(TextInserter.pasteOutcome(preValue: TextInserter.verifiableValue(docs), landed: false), .inserted)
    }

    /// An empty field, or invisible characters among visible text, is still real text and stays verified.
    func testRealFieldsAreNotStandIns() {
        XCTAssertEqual(TextInserter.verifiableValue(FakeField(caret: 0, value: "")), "")
        XCTAssertEqual(TextInserter.verifiableValue(FakeField(caret: 3, value: "a\u{200B}b")), "a\u{200B}b")
        let long = String(repeating: "\u{200B}", count: 9)
        XCTAssertEqual(TextInserter.verifiableValue(FakeField(caret: 9, value: long)), long)
    }

    /// No focused element (Steam / E16): no preValue can be read, so the blind paste counts as inserted.
    func testNilFieldBlindPasteCountsAsInserted() {
        let field: FocusedField? = nil
        XCTAssertEqual(TextInserter.pasteOutcome(preValue: field?.value, landed: false), .inserted)
    }
}
