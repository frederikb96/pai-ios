import XCTest

@testable import PAIKit

/// The hanging indent an editor hangs a wrapped list-item continuation from — one entry per
/// list line, silence for everything else.
final class MarkdownHangingIndentTests: XCTestCase {

    func testAPlainParagraphProducesNoIndent() {
        XCTAssertEqual(MarkdownHangingIndent.indents(for: "just a paragraph\n"), [])
    }

    func testABulletLineIsIndentedByItsMarkerWidth() {
        let indents = MarkdownHangingIndent.indents(for: "- one\n")
        XCTAssertEqual(indents, [MarkdownHangingIndent(location: 0, length: 6, markerWidth: 2)])
    }

    /// Only list lines are reported — a heading beside a list contributes nothing, and its
    /// absence from the result is how a caller tells "no indent" from "zero-width indent".
    func testANonListLineBetweenTwoListLinesIsSkipped() {
        let source = "- one\nplain\n- two\n"
        let indents = MarkdownHangingIndent.indents(for: source)
        XCTAssertEqual(indents.map(\.markerWidth), [2, 2])
        XCTAssertEqual(indents.map(\.location), [0, 12])
    }

    /// The location and length are UTF-16 offsets into the whole source, terminator included —
    /// what an `NSAttributedString` paragraph-style range is set over.
    func testLocationsAreUtf16OffsetsIntoTheWholeSource() {
        let source = "- 🎉 one\n- two\n"
        let indents = MarkdownHangingIndent.indents(for: source)
        XCTAssertEqual(indents.count, 2)
        XCTAssertEqual(indents[0].location, 0)
        XCTAssertEqual(indents[0].length, "- 🎉 one\n".utf16.count)
        XCTAssertEqual(indents[1].location, "- 🎉 one\n".utf16.count)
    }

    func testATaskItemsIndentIncludesTheCheckbox() {
        let indents = MarkdownHangingIndent.indents(for: "- [ ] todo\n")
        XCTAssertEqual(indents.first?.markerWidth, 6)
    }

    /// A CRLF-terminated list still gets an indent, and the reported length carries the whole
    /// two-character terminator — the same `isNewline`-based splitting the line splitters use.
    func testACrlfTerminatedBulletLineIsStillIndented() {
        let indents = MarkdownHangingIndent.indents(for: "- one\r\n- two\r\n")
        XCTAssertEqual(indents.map(\.markerWidth), [2, 2])
        XCTAssertEqual(indents[0].length, 7)
        XCTAssertEqual(indents[1].location, 7)
    }

    func testAnEmptySourceHasNoIndents() {
        XCTAssertEqual(MarkdownHangingIndent.indents(for: ""), [])
    }

    /// A thematic break reads exactly like a marker-less line of dashes to `Marker`'s own parser
    /// — `MarkdownListContinuationTests` already covers that at the `onReturn` layer; this
    /// confirms the same holds through `markerPrefixLength`, which a hanging indent depends on.
    func testAThematicBreakHasNoIndent() {
        XCTAssertEqual(MarkdownHangingIndent.indents(for: "---\n"), [])
    }
}
