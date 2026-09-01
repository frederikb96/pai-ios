import XCTest

@testable import PAIKit

/// The line-level primitives the source highlighter builds on. Getting these wrong is not a
/// crash — it is a fence that never closes, or a paragraph mistaken for a table, which reads as
/// the highlighter losing track of where it is.
final class MarkdownLineSyntaxTests: XCTestCase {

    // MARK: Fences

    func testABacktickFenceOpens() {
        XCTAssertEqual(MarkdownLineSyntax.openingFence(in: "```swift\n"), "```")
    }

    func testATildeFenceOpens() {
        XCTAssertEqual(MarkdownLineSyntax.openingFence(in: "~~~\n"), "~~~")
    }

    /// Inline code is not a fence. Three backticks on one line with content around them opens
    /// nothing — treating it as one would swallow the rest of the note.
    func testInlineCodeDoesNotOpenAFence() {
        XCTAssertNil(MarkdownLineSyntax.openingFence(in: "use ```code``` here\n"))
    }

    /// A fence indented four spaces is CommonMark's indented code block, not a fence.
    func testAFenceIndentedFourSpacesDoesNotOpen() {
        XCTAssertNil(MarkdownLineSyntax.openingFence(in: "    ```\n"))
    }

    /// CommonMark's rule: a closing run must be at least as long as the opener, which is why a
    /// shorter fence nested inside a longer one is content rather than a close.
    func testAShorterRunDoesNotCloseALongerFence() {
        XCTAssertFalse(MarkdownLineSyntax.closesFence("```\n", opener: "````"))
    }

    func testAMatchingRunCloses() {
        XCTAssertTrue(MarkdownLineSyntax.closesFence("```\n", opener: "```"))
    }

    /// Nothing but whitespace may follow a closing fence — trailing content makes it just another
    /// content line, not a close.
    func testAClosingFenceMayNotHaveTrailingContent() {
        XCTAssertFalse(MarkdownLineSyntax.closesFence("``` trailing\n", opener: "```"))
    }

    // MARK: Table delimiter

    func testAnOrdinaryDelimiterRowIsRecognised() {
        XCTAssertTrue(MarkdownLineSyntax.isTableDelimiter("| --- | :-: |\n"))
    }

    /// The delimiter row is what makes a table a table in GFM — plain pipe lines with no dashes
    /// are just lines.
    func testPipeLinesWithNoDashesAreNotADelimiter() {
        XCTAssertFalse(MarkdownLineSyntax.isTableDelimiter("| a | b |\n"))
    }

    /// A setext heading's `---` alone satisfies every structural rule a single-column delimiter
    /// needs — but it never begins with a pipe, so it must not be read as one.
    func testABareRuleIsNotATableDelimiter() {
        XCTAssertFalse(MarkdownLineSyntax.isTableDelimiter("---\n"))
    }

    // MARK: Line splitting

    func testSplitKeepsEachLinesTerminator() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators("a\nb\n"), ["a\n", "b\n"])
    }

    /// Swift clusters `\r\n` into a single `Character` that equals neither a bare `\r` nor a bare
    /// `\n` — checking `isNewline` rather than the two literals is what lets this scan see the
    /// boundary anyway, and keep the terminator attached to the line it ends.
    func testACrlfTerminatedNoteSplitsAtEachLine() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators("a\r\nb\r\n"), ["a\r\n", "b\r\n"])
    }

    /// A lone `\r` (old Mac style, never followed by `\n`) is also `isNewline` and splits the
    /// same way — not only the CRLF pair.
    func testALoneCarriageReturnAlsoSplits() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators("a\rb\r"), ["a\r", "b\r"])
    }

    /// A fence closes on a CRLF-terminated line exactly as it would on a bare `\n` one — the
    /// trailing-whitespace check after the closing run has to see the terminator as whitespace
    /// either way.
    func testAFenceClosesOnACrlfTerminatedLine() {
        XCTAssertTrue(MarkdownLineSyntax.closesFence("```\r\n", opener: "```"))
    }

    func testSplitKeepsALoneTrailingLineWithNoTerminator() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators("a\nb"), ["a\n", "b"])
    }

    func testSplitOfAnEmptyDocumentIsEmpty() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators(""), [])
    }
}
