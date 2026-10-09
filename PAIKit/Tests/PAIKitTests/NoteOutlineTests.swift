import XCTest
@testable import PAIKit

final class NoteOutlineTests: XCTestCase {

    func testHeadingLevelsAreCountedFromHashRun() {
        let entries = parseOutline("# One\n## Two\n### Three")
        XCTAssertEqual(entries.map(\.level), [1, 2, 3])
        XCTAssertEqual(entries.map(\.text), ["One", "Two", "Three"])
    }

    /// The offset is what a tap jumps to — it must point at the START of the heading's own line,
    /// not at some position relative to the match within it.
    func testOffsetPointsAtStartOfHeadingLine() {
        let body = "intro\n# Heading"
        let entries = parseOutline(body)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].offset, 6)
        let idx = body.index(body.startIndex, offsetBy: entries[0].offset)
        XCTAssertEqual(String(body[idx...]), "# Heading")
    }

    /// A line starting with `#` but no following space is a hashtag or a comment, not a heading —
    /// matches CommonMark ATX rules, which require the space.
    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertTrue(parseOutline("#nospace").isEmpty)
    }

    /// More than six `#` characters is not a valid ATX heading level.
    func testSevenHashesIsNotAHeading() {
        XCTAssertTrue(parseOutline("####### Too Many").isEmpty)
    }

    func testTrailingWhitespaceIsTrimmedFromHeadingText() {
        let entries = parseOutline("## Heading With Space   ")
        XCTAssertEqual(entries.first?.text, "Heading With Space")
    }

    func testSetextHeadingsAreNotParsed() {
        // The editor this app writes with never produces setext (`===`/`---`) headings, so
        // parsing for them would find headings the editor itself cannot create.
        XCTAssertTrue(parseOutline("Title\n=====").isEmpty)
    }

    func testEmptyBodyProducesNoEntries() {
        XCTAssertTrue(parseOutline("").isEmpty)
    }

    func testHashLinesInsideBacktickAndTildeFencesAreNotHeadings() {
        XCTAssertEqual(parseOutline("```bash\n# comment\n```\n# Real").map(\.text), ["Real"])
        XCTAssertEqual(parseOutline("~~~\n# fake\n~~~\n## Real").map(\.text), ["Real"])
    }

    /// A closing fence must match the opener's character and be at least as long, so a shorter or
    /// different run inside the block does not end it.
    func testOnlyAMatchingFenceClosesTheBlock() {
        let body = "````\n```\n# a\n~~~~\n# b\n````\n# c"
        XCTAssertEqual(parseOutline(body).map(\.text), ["c"])
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(parseOutline("# a\n```\n# b\n# c").map(\.text), ["a"])
    }

    func testOffsetsAfterAFenceStillPointAtTheirLine() {
        let body = "```\n# x\n```\n# Real"
        let entry = parseOutline(body)[0]
        XCTAssertEqual(String(body.dropFirst(entry.offset)), "# Real")
    }
}
