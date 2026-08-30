import XCTest

@testable import PAIKit

/// The property everything else rests on: a note that goes through the editor and comes back
/// unchanged must be byte-identical. These are Freddy's real vault files — an editor that
/// normalises a blank line rewrites notes nobody edited, and the sync engine then pushes that
/// rewrite to disk.
final class NoteSegmentationRoundTripTests: XCTestCase {

    private func assertRoundTrips(_ source: String, file: StaticString = #filePath, line: UInt = #line) {
        let segments = NoteSegmentation.split(source)
        XCTAssertEqual(
            NoteSegmentation.join(segments), source, "did not round-trip", file: file, line: line)
    }

    func testRoundTripsOrdinaryProse() {
        assertRoundTrips("# Title\n\nSome text.\n\nMore text.\n")
    }

    func testRoundTripsADocumentWithNoTrailingNewline() {
        assertRoundTrips("just one line")
    }

    func testRoundTripsWindowsLineEndings() {
        assertRoundTrips("# Title\r\n\r\n```sh\r\necho hi\r\n```\r\n\r\ntail\r\n")
    }

    func testRoundTripsALoneCarriageReturn() {
        assertRoundTrips("a\rb\rc")
    }

    func testRoundTripsConsecutiveBlankLines() {
        assertRoundTrips("a\n\n\n\n\nb\n")
    }

    func testRoundTripsAnUnterminatedFence() {
        assertRoundTrips("text\n\n```swift\nlet x = 1\n")
    }

    func testRoundTripsATableAtTheVeryEnd() {
        assertRoundTrips("| a | b |\n| - | - |\n| 1 | 2 |")
    }

    func testRoundTripsAnEmptyDocument() {
        assertRoundTrips("")
    }

    func testRoundTripsFrontmatterFollowedByCode() {
        assertRoundTrips("---\nid: 1\n---\n\n```\ncode\n```\n")
    }

    func testRoundTripsTrailingWhitespaceOnALine() {
        assertRoundTrips("a line with trailing spaces   \nand another\n")
    }
}

/// What is split off, and what is deliberately left alone. Getting these wrong is not a crash —
/// it is text that wraps when it should scroll, or the reverse, which reads as a broken editor.
final class NoteSegmentationSplittingTests: XCTestCase {

    func testAFencedBlockBecomesItsOwnSegment() {
        let segments = NoteSegmentation.split("before\n\n```sh\necho hi\n```\n\nafter\n")
        XCTAssertEqual(segments.map(\.kind), [.prose, .codeBlock, .prose])
        XCTAssertEqual(segments[1].text, "```sh\necho hi\n```\n")
    }

    func testATableBecomesItsOwnSegment() {
        let segments = NoteSegmentation.split("intro\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nend\n")
        XCTAssertEqual(segments.map(\.kind), [.prose, .table, .prose])
        XCTAssertEqual(segments[1].text, "| a | b |\n|---|---|\n| 1 | 2 |\n")
    }

    /// The reason prose is one region rather than one per paragraph: everything between two
    /// code blocks stays a single editable text view, so paragraph breaks and list continuation
    /// are UIKit's job rather than something reimplemented across views.
    func testAllProseBetweenTwoBlocksIsOneSegment() {
        let segments = NoteSegmentation.split(
            "```\na\n```\n\n# Heading\n\npara one\n\n- item\n- item\n\n```\nb\n```\n")
        XCTAssertEqual(segments.map(\.kind), [.codeBlock, .prose, .codeBlock])
    }

    /// A pipe in a sentence is not a table, and treating it as one would stop that paragraph
    /// wrapping — which looks like the editor breaking on ordinary text.
    func testAPipeInASentenceIsNotATable() {
        let segments = NoteSegmentation.split("run `a | b` and see\n")
        XCTAssertEqual(segments.map(\.kind), [.prose])
    }

    /// The delimiter row is what makes a table a table in GFM. Without it these are just lines.
    func testPipeLinesWithNoDelimiterRowAreNotATable() {
        let segments = NoteSegmentation.split("| a | b |\n| c | d |\n")
        XCTAssertEqual(segments.map(\.kind), [.prose])
    }

    /// A setext heading is written as text followed by `---`, and `---` alone satisfies every
    /// structural rule a single-column delimiter row has. If the line above it happens to mention
    /// a pipe — `use a | b`, and prose does — the pair reads as a table and that paragraph stops
    /// wrapping.
    func testAProseLineWithAPipeAboveARuleIsNotATable() {
        let segments = NoteSegmentation.split("choose a | b here\n---\n\nafter\n")
        XCTAssertEqual(segments.map(\.kind), [.prose])
    }

    /// A table absorbs the lines under it, and a paragraph that happens to contain a pipe is not
    /// one of them — swallowed, it would be laid out unwrapped and scroll sideways.
    func testProseAfterATableIsNotSwallowedByIt() {
        let segments = NoteSegmentation.split("| a | b |\n|---|---|\n| 1 | 2 |\nthen a | pipe in prose\n")
        XCTAssertEqual(segments.map(\.kind), [.table, .prose])
        XCTAssertEqual(segments[0].text, "| a | b |\n|---|---|\n| 1 | 2 |\n")
    }

    /// Inline code is not a fence. Three backticks on one line with content around them opens
    /// nothing, and treating it as a fence would swallow the rest of the note.
    func testInlineCodeDoesNotOpenAFence() {
        let segments = NoteSegmentation.split("use ```code``` here\n\nnext para\n")
        XCTAssertEqual(segments.map(\.kind), [.prose])
    }

    /// CommonMark's rule, and the reason it matters here: a shorter run inside a longer fence is
    /// content, so a block demonstrating markdown stays one block instead of splitting in three.
    func testAShorterFenceInsideALongerOneDoesNotCloseIt() {
        let source = "````\n```\ninner\n```\n````\n"
        let segments = NoteSegmentation.split(source)
        XCTAssertEqual(segments.map(\.kind), [.codeBlock])
        XCTAssertEqual(segments[0].text, source)
    }

    func testATildeFenceIsAFence() {
        let segments = NoteSegmentation.split("~~~\ncode\n~~~\n")
        XCTAssertEqual(segments.map(\.kind), [.codeBlock])
    }

    /// A fence indented four spaces is an indented code block in CommonMark, not a fence — and
    /// more to the point, inside a list item it is content. Opening a segment on it would split
    /// a list in half.
    func testAFenceIndentedFourSpacesDoesNotOpenABlock() {
        let segments = NoteSegmentation.split("text\n\n    ```\n    not a fence\n")
        XCTAssertEqual(segments.map(\.kind), [.prose])
    }

    func testAClosingFenceMayNotHaveTrailingContent() {
        let segments = NoteSegmentation.split("```\ncode\n``` trailing\n```\n")
        XCTAssertEqual(segments.map(\.kind), [.codeBlock])
        XCTAssertEqual(segments[0].text, "```\ncode\n``` trailing\n```\n")
    }
}

/// Editing one segment re-splits the whole note, which is what lets structure follow the text
/// instead of drifting from it.
final class NoteSegmentationEditingTests: XCTestCase {

    /// Typing a fence into a paragraph has to turn it into a code block with no rule of its own.
    func testTypingAFenceTurnsProseIntoACodeBlock() {
        let segments = NoteSegmentation.split("hello\n")
        let updated = NoteSegmentation.replacing(0, with: "```\nhello\n```\n", in: segments)
        XCTAssertEqual(updated.map(\.kind), [.codeBlock])
    }

    /// And deleting it has to turn it back — the case that would strand text in a
    /// horizontally-scrolling region it can never leave.
    func testDeletingAFenceTurnsACodeBlockBackIntoProse() {
        let segments = NoteSegmentation.split("```\nhello\n```\n")
        let updated = NoteSegmentation.replacing(0, with: "hello\n", in: segments)
        XCTAssertEqual(updated.map(\.kind), [.prose])
    }

    /// The seam case: deleting the fence between two prose regions has to merge them, not leave
    /// two regions with an invisible boundary the caret cannot cross.
    func testRemovingABlockMergesTheProseAroundIt() {
        let segments = NoteSegmentation.split("before\n\n```\ncode\n```\n\nafter\n")
        XCTAssertEqual(segments.count, 3)
        let updated = NoteSegmentation.replacing(1, with: "", in: segments)
        XCTAssertEqual(updated.map(\.kind), [.prose])
        XCTAssertEqual(NoteSegmentation.join(updated), "before\n\n\nafter\n")
    }

    /// Edited through `withDisplayText`, which is what the editor does — the separators the
    /// reader never sees survive, so the file keeps its blank lines exactly.
    func testAnEditPreservesTheSeparatorsAroundIt() {
        let segments = NoteSegmentation.split("a\n\n```\ncode\n```\n\nb\n")
        let edited = segments[2].withDisplayText("b changed")
        let updated = NoteSegmentation.replacing(2, with: edited.text, in: segments)
        XCTAssertEqual(NoteSegmentation.join(updated), "a\n\n```\ncode\n```\n\nb changed\n")
    }

    func testAnOutOfRangeIndexChangesNothing() {
        let segments = NoteSegmentation.split("a\n")
        XCTAssertEqual(NoteSegmentation.replacing(7, with: "x", in: segments), segments)
    }
}

/// A segment's separators are the blank lines around it. The reader never sees them, and the
/// file must keep them — an editor that showed them would open every region after a code block
/// with an empty first line, and one that dropped them would reflow the whole note.
final class NoteSegmentDisplayTextTests: XCTestCase {

    private func assertDisplayRoundTrips(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let segment = NoteSegment(kind: .prose, text: text)
        XCTAssertEqual(
            segment.withDisplayText(segment.displayText).text, text,
            "display round trip lost something", file: file, line: line)
    }

    func testTheBlankLineAfterACodeBlockIsNotShown() {
        let segments = NoteSegmentation.split("```\nc\n```\n\ntail\n")
        XCTAssertEqual(segments[1].displayText, "tail")
        XCTAssertEqual(segments[1].leadingSeparator, "\n")
    }

    func testACodeBlockShowsItsOwnFences() {
        let segments = NoteSegmentation.split("```sh\necho\n```\n")
        XCTAssertEqual(segments[0].displayText, "```sh\necho\n```")
    }

    /// Indentation is content, not separation. Trimming it would silently dedent every list.
    func testLeadingSpacesAreContentNotSeparation() {
        let segment = NoteSegment(kind: .prose, text: "    indented\n")
        XCTAssertEqual(segment.displayText, "    indented")
        XCTAssertEqual(segment.leadingSeparator, "")
    }

    /// A gap between two code blocks is a segment that is nothing but separator. Reading its
    /// display text as anything other than empty would put stray blank lines on screen.
    func testASegmentThatIsOnlySeparatorShowsNothing() {
        let segment = NoteSegment(kind: .prose, text: "\n\n")
        XCTAssertEqual(segment.displayText, "")
        assertDisplayRoundTrips("\n\n")
    }

    func testDisplayTextRoundTripsForAwkwardShapes() {
        for text in ["a", "a\n", "\na", "\n\na\n\n", "", "\r\na\r\n", "a\n\nb"] {
            assertDisplayRoundTrips(text)
        }
    }

    /// Typing into an empty gap has to produce text with the gap's blank lines still around it,
    /// or the paragraph fuses onto the code block above.
    func testTypingIntoAnEmptyGapKeepsItSeparated() {
        let segment = NoteSegment(kind: .prose, text: "\n\n")
        XCTAssertEqual(segment.withDisplayText("new").text, "\n\nnew")
    }
}
