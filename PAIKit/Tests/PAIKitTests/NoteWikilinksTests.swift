import XCTest
@testable import PAIKit

/// `findWikilinks`/`splitBodyForRender` are what makes a link clickable or visibly dead — a
/// regression here either breaks navigation silently or mistakes ordinary code for a link, both
/// of which pass every other check in the app.
final class NoteWikilinksTests: XCTestCase {

    func testPlainWikilinkIsFound() {
        let links = findWikilinks("See [[Some Note]] for details.")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "Some Note")
        XCTAssertFalse(links[0].isEmbed)
        XCTAssertNil(links[0].alias)
        XCTAssertNil(links[0].heading)
    }

    func testAliasAndHeadingAreSplitOff() {
        let links = findWikilinks("[[Target#Some Heading|Display Text]]")
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "Target")
        XCTAssertEqual(links[0].heading, "Some Heading")
        XCTAssertEqual(links[0].alias, "Display Text")
    }

    func testEmbedIsMarkedIsEmbed() {
        let links = findWikilinks("![[attachments/photo.png]]")
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].isEmbed)
        XCTAssertEqual(links[0].target, "attachments/photo.png")
    }

    /// The exact scenario the module doc comment names: a shell snippet using bash's `[[ ]]` test
    /// syntax inside an inline code span must never be mistaken for a link.
    func testWikilinkSyntaxInsideInlineCodeIsIgnored() {
        let links = findWikilinks("Run `if [[ \"$X\" == *\"-\"* ]]; then` in bash.")
        XCTAssertTrue(links.isEmpty, "expected no links, found \(links)")
    }

    func testWikilinkSyntaxInsideFencedCodeBlockIsIgnored() {
        let body = """
            Some text.
            ```
            if [[ "$X" == *"-"* ]]; then
            echo yes
            fi
            ```
            [[Real Link]]
            """
        let links = findWikilinks(body)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "Real Link")
    }

    /// A fence must be closed by the SAME character and AT LEAST the same run length — a shorter
    /// or differently-charactered line inside the block must not close it early.
    func testFenceRequiresMatchingCharacterAndLength() {
        let body = """
            ```
            ~~~
            [[Inside Both]]
            ```
            [[Outside]]
            """
        let links = findWikilinks(body)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "Outside")
    }

    func testResolvedWikilinkBecomesMarkdownLink() {
        let segments = splitBodyForRender("See [[Target]] here.", nameToId: ["target": "note-123"])
        guard case .text(let markdown) = segments.first else {
            return XCTFail("expected a text segment")
        }
        XCTAssertTrue(markdown.contains("[Target](pai-note://note-123)"), markdown)
    }

    /// A wikilink whose target isn't in the loaded index has to read as visibly broken, not
    /// silently disappear or link to nothing.
    func testUnresolvedWikilinkBecomesStrikethrough() {
        let segments = splitBodyForRender("See [[Missing Note]] here.", nameToId: [:])
        guard case .text(let markdown) = segments.first else {
            return XCTFail("expected a text segment")
        }
        XCTAssertTrue(markdown.contains("~~Missing Note~~"), markdown)
    }

    /// A container is a flat folder, and Obsidian resolves a bare wikilink by its last path
    /// component — a target written with a directory prefix must still resolve.
    func testTargetResolvesByLastPathComponent() {
        let segments = splitBodyForRender("[[folder/Target]]", nameToId: ["target": "note-9"])
        guard case .text(let markdown) = segments.first else {
            return XCTFail("expected a text segment")
        }
        XCTAssertTrue(markdown.contains("pai-note://note-9"), markdown)
    }

    func testEmbedProducesItsOwnSegmentSeparateFromSurroundingText() {
        let segments = splitBodyForRender("before ![[attachments/x.png]] after", nameToId: [:])
        XCTAssertEqual(segments.count, 3)
        guard case .text(let before) = segments[0] else { return XCTFail("expected text") }
        XCTAssertEqual(before, "before ")
        guard case .embed(let target, _) = segments[1] else { return XCTFail("expected embed") }
        XCTAssertEqual(target, "attachments/x.png")
        guard case .text(let after) = segments[2] else { return XCTFail("expected text") }
        XCTAssertEqual(after, " after")
    }

    func testBodyWithNoLinksIsOneWholeTextSegment() {
        let segments = splitBodyForRender("Just plain text.", nameToId: [:])
        XCTAssertEqual(segments, [.text("Just plain text.")])
    }
}
