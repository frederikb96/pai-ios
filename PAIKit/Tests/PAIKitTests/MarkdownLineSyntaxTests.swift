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
    /// `\n`, so this line-by-line scan cannot see a boundary inside one — the whole string comes
    /// back as one "line" rather than being split at each CRLF. Whatever reads these lines to
    /// find a fence or a table delimiter is blind to that boundary too; recorded here as the
    /// actual, current behaviour rather than assumed from the terminator-preserving intent above.
    func testACrlfPairIsOneUnbrokenCharacterNotATerminatorThisScansOn() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators("a\r\nb\r\n"), ["a\r\nb\r\n"])
    }

    func testSplitKeepsALoneTrailingLineWithNoTerminator() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators("a\nb"), ["a\n", "b"])
    }

    func testSplitOfAnEmptyDocumentIsEmpty() {
        XCTAssertEqual(MarkdownLineSyntax.splitKeepingTerminators(""), [])
    }
}
