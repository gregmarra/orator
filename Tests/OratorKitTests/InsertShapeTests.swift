import XCTest
@testable import OratorKit

/// The insertion shape line must stay content-free: one escaped character of context, a title tail
/// with no document name, and nothing else from the host field.
final class InsertShapeTests: XCTestCase {
    private func shape(last: Character?) -> InsertShape {
        InsertShape(build: "30·8cea807", app: "com.google.Chrome", windowTitleTail: "Google Docs", role: "AXTextArea",
                    subrole: nil, domID: nil, contextSource: .range, contextLength: 64,
                    lastCharacter: last, leadingSpace: last.map { !$0.isWhitespace } ?? false,
                    startsSentence: false, valueLengthBefore: 4321, verification: .rejected)
    }

    func testDescriptionCarriesOneEscapedCharacter() {
        XCTAssertTrue(shape(last: "e").description.contains(#"last="e""#))
        XCTAssertTrue(shape(last: "\n").description.contains(#"last="\n""#))
        XCTAssertTrue(shape(last: " ").description.contains(#"last=" ""#))
        XCTAssertTrue(shape(last: nil).description.contains("last=nil"))
    }

    func testDescriptionNamesEveryDecisionAndTheOutcome() {
        let line = shape(last: "e").description
        for field in ["build=30·8cea807", "app=com.google.Chrome", "win=\"Google Docs\"", "role=AXTextArea", "subrole=nil",
                      "ctx=range", "ctxLen=64", "space=true", "sentence=false", "preLen=4321",
                      "verify=rejected"] {
            XCTAssertTrue(line.contains(field), "missing \(field) in: \(line)")
        }
    }

    func testTitleTailDropsTheDocumentName() {
        XCTAssertEqual(InsertShape.titleTail(of: "Q3 budget - notes - Google Docs - Greg"), "Google Docs - Greg")
        XCTAssertEqual(InsertShape.titleTail(of: "Q3 budget - Google Docs"), "Q3 budget - Google Docs")
        XCTAssertEqual(InsertShape.titleTail(of: "Untitled"), "Untitled")
        XCTAssertEqual(InsertShape.titleTail(of: String(repeating: "x", count: 100)).count, 40)
    }
}
