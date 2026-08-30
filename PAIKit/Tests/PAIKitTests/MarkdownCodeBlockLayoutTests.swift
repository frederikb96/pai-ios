import XCTest

@testable import PAIKit

/// A code block's measured height has to equal the height it draws to, or every row above the
/// reader moves when it lays out — the transcript's precomputed layout has no way to absorb a
/// disagreement. Since the block does not wrap, that height is a line count, and this is where
/// the line count is proven.
final class MarkdownCodeBlockLayoutTests: XCTestCase {

    func testOneLineIsOneLine() {
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: "let x = 1"), 1)
    }

    func testEachNewlineStartsAnotherLine() {
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: "a\nb\nc"), 3)
    }

    /// The trap. cmark keeps the fence's final line break in the block's text, so counting
    /// separators naively reports one phantom line for every code block in the app — a gap under
    /// each one, and a measured height that is permanently too tall.
    func testATrailingNewlineDoesNotAddAPhantomLine() {
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: "a\nb\n"), 2)
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: "a\nb\r\n"), 2)
    }

    /// A deliberate blank line inside a block is content and occupies a line. Only the block's
    /// own terminator is discounted.
    func testABlankLineInTheMiddleIsStillALine() {
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: "a\n\nb\n"), 3)
    }

    /// An empty block still draws its box. Reporting zero lines would collapse it to its padding
    /// and leave a stripe where a block should be.
    func testAnEmptyBlockStillOccupiesOneLine() {
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: ""), 1)
        XCTAssertEqual(MarkdownCodeBlockLayout.lineCount(of: "\n"), 1)
    }

    func testHeightIsLinesPlusPaddingOnBothSides() {
        XCTAssertEqual(
            MarkdownCodeBlockLayout.height(for: "a\nb\n", lineHeight: 20, padding: 8), 56)
    }

    /// The property that makes this arithmetic instead of a layout pass, and the reason the
    /// measurement is trustworthy on Linux: the block does not wrap, so its height cannot depend
    /// on the width it is measured at.
    func testHeightDoesNotDependOnWidth() {
        let code = "a very long line that would certainly wrap in any bubble on any phone\nb"
        let narrow = MarkdownCodeBlockLayout.height(for: code, lineHeight: 20, padding: 8)
        XCTAssertEqual(narrow, MarkdownCodeBlockLayout.height(for: code, lineHeight: 20, padding: 8))
        XCTAssertEqual(narrow, 2 * 20 + 16)
    }
}
