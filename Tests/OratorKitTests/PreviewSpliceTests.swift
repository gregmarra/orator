import XCTest
@testable import OratorKit

final class PreviewSpliceTests: XCTestCase {
    func testAccurateWordsReplaceThePreviewsVersionOfThem() {
        // The preview misheard "the band" as "a van"; the accurate final has it right.
        XCTAssertEqual(PreviewSplice.compose(confirmed: "while the band plays on.",
                                             preview: "while a van plays on and the crowd"),
                       "while the band plays on. and the crowd")
    }

    func testNothingConfirmedShowsThePreview() {
        XCTAssertEqual(PreviewSplice.compose(confirmed: "", preview: "hello there"), "hello there")
    }

    /// The preview can lag the accurate text (it was dropped or restarted): show only what's confirmed.
    func testPreviewBehindTheAccurateTextAddsNothing() {
        XCTAssertEqual(PreviewSplice.compose(confirmed: "one two three four", preview: "one two"), "one two three four")
    }

    /// A phrase said twice must not re-show the covered copy.
    func testRepeatedPhraseUsesTheLatestAlignment() {
        XCTAssertEqual(PreviewSplice.compose(confirmed: "go home. go home.", preview: "go home go home now please"),
                       "go home. go home. now please")
    }

    /// Past the window the alignment matches only the confirmed tail, anywhere in the preview.
    func testLongDictationAlignsOnTheTail() {
        let confirmed = (1...100).map { "w\($0)" }.joined(separator: " ")
        let preview = (1...104).map { "w\($0)" }.joined(separator: " ")
        XCTAssertEqual(PreviewSplice.compose(confirmed: confirmed, preview: preview), confirmed + " w101 w102 w103 w104")
    }
}
