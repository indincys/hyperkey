import XCTest

@testable import Hyper

/// Every transform is a pure `String -> String`, so the interesting cases are the empty
/// input, runs of whitespace, and text that is not ASCII.
final class PasteTransformTests: XCTestCase {
    func testEmptyStringIsUnchangedByEveryTransform() {
        for transform in PasteTransform.allCases {
            XCTAssertEqual(transform.apply(to: ""), "", "\(transform.rawValue) changed the empty string")
        }
    }

    func testCaseTransforms() {
        XCTAssertEqual(PasteTransform.uppercase.apply(to: "héllo wörld"), "HÉLLO WÖRLD")
        XCTAssertEqual(PasteTransform.lowercase.apply(to: "HÉLLO WÖRLD"), "héllo wörld")
        XCTAssertEqual(PasteTransform.titleCase.apply(to: "héllo wörld"), "Héllo Wörld")
        // Title case lowercases the rest of each word, which is what Title Case means.
        XCTAssertEqual(PasteTransform.titleCase.apply(to: "HELLO WORLD"), "Hello World")
    }

    func testCaseTransformsLeaveCasclessScriptsAlone() {
        let text = "剪贴板 🎉 テスト"
        XCTAssertEqual(PasteTransform.uppercase.apply(to: text), text)
        XCTAssertEqual(PasteTransform.lowercase.apply(to: text), text)
    }

    func testTrimmedTouchesOnlyTheEnds() {
        XCTAssertEqual(PasteTransform.trimmed.apply(to: "\t\n  中文 内容  \n"), "中文 内容")
        // Interior blank lines survive; only the ends are cut.
        XCTAssertEqual(PasteTransform.trimmed.apply(to: "  a\n\n\nb  "), "a\n\n\nb")
        XCTAssertEqual(PasteTransform.trimmed.apply(to: " \n\t "), "")
    }

    func testCollapseBlankLinesKeepsSingleBreaks() {
        XCTAssertEqual(PasteTransform.collapseBlankLines.apply(to: "a\nb"), "a\nb")
        XCTAssertEqual(PasteTransform.collapseBlankLines.apply(to: "a\n\nb"), "a\n\nb")
        XCTAssertEqual(PasteTransform.collapseBlankLines.apply(to: "a\n\n\n\n\nb"), "a\n\nb")
        // A "blank" line may hold spaces and tabs and is still blank.
        XCTAssertEqual(PasteTransform.collapseBlankLines.apply(to: "a\n   \n\t\nb"), "a\n\nb")
        // CRLF normalises to the same single blank line.
        XCTAssertEqual(PasteTransform.collapseBlankLines.apply(to: "a\r\n\r\n\r\nb"), "a\n\nb")
    }

    func testSingleLineCollapsesEveryRunOfWhitespace() {
        XCTAssertEqual(PasteTransform.singleLine.apply(to: "  a\n\n\tb  "), "a b")
        XCTAssertEqual(PasteTransform.singleLine.apply(to: "第一行\n第二行"), "第一行 第二行")
        XCTAssertEqual(PasteTransform.singleLine.apply(to: " \n\t "), "")
    }

    func testEveryCaseHasADistinctIdentifierAndLabel() {
        let ids = Set(PasteTransform.allCases.map(\.id))
        let labels = Set(PasteTransform.allCases.map(\.label))
        XCTAssertEqual(ids.count, PasteTransform.allCases.count)
        XCTAssertEqual(labels.count, PasteTransform.allCases.count)
    }
}
