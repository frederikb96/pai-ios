import Foundation
import XCTest

@testable import PAIKit

/// The cases mirror the web's `NoteBodyView.tags.test.tsx` (what its read view draws as a chip)
/// and the server's `test_notes_tags.py` (what the tag filter lists): the same words must be a
/// tag on all three sides, so a chip always filters to something and a listed tag is always
/// drawn.
final class NoteInlineTagsTests: XCTestCase {

    /// The tags a note body draws as chips, found through the same parse the read view uses.
    private func drawn(_ body: String) -> [String] {
        let document = NotePreviewDocument(body: body, nameToId: [:])
        var found: [String] = []
        func visit(_ block: MarkdownBlock) {
            switch block {
            case .paragraph(let text), .heading(_, let text):
                for run in NoteInlineTags.tagged(text).runs where run.style.contains(.noteTag) {
                    found.append(run.text)
                }
            case .blockQuote(let nested):
                nested.forEach(visit)
            case .list(let list):
                list.items.forEach { $0.blocks.forEach(visit) }
            default:
                break
            }
        }
        document.items.forEach { visit($0.block) }
        return found
    }

    func testEachTagInProseIsDrawnAndTheWordsAroundItAreUntouched() {
        XCTAssertEqual(drawn("Filed under #pai and #report/weekly today"), ["#pai", "#report/weekly"])
        let text = InlineText(runs: [InlineRun(text: "Filed under #pai and #report/weekly today")])
        XCTAssertEqual(NoteInlineTags.tagged(text).plainText, text.plainText)
    }

    func testATagAtTheStartOfALineInAListAndAfterALineBreakIsDrawn() {
        XCTAssertEqual(drawn("#first\n#second line\n\n- item #third"), ["#first", "#second", "#third"])
    }

    func testCodeLinksHeadingMarkersUrlFragmentsAndNumberingAreLeftAlone() {
        let body = [
            "# Heading #real",
            "",
            "```",
            "#!/bin/sh",
            "# comment #nottag",
            "```",
            "",
            "inline `#code` and [link #label](https://example.com/#frag) and https://example.com/#anchor",
            "",
            "issue #123 and #2026 and word#glued and **bold**#glued",
        ].joined(separator: "\n")
        XCTAssertEqual(drawn(body), ["#real"])
    }

    func testATrailingSeparatorIsPunctuation() {
        XCTAssertEqual(drawn("see #project/ for more, or #ops- instead"), ["#project", "#ops"])
        XCTAssertEqual(
            NoteInlineTags.pieces(in: "see #project/ for more"),
            [
                .text("see "), .tag("project"), .text("/ for more"),
            ])
    }

    func testTagsWithNonAsciiLettersAndUnderscores() {
        XCTAssertEqual(drawn("#größe und #_intern und #日本語"), ["#größe", "#_intern", "#日本語"])
    }

    func testTheCharacterAheadOfTheTextDecidesWhetherItsFirstHashOpensATag() {
        XCTAssertEqual(NoteInlineTags.pieces(in: "#x", after: "b"), [])
        XCTAssertEqual(NoteInlineTags.pieces(in: "#x", after: " "), [.tag("x")])
        XCTAssertEqual(NoteInlineTags.pieces(in: "#x", after: nil), [.tag("x")])
    }

    /// A tag drawn as a chip carries a link that reads back as the same tag, whatever it holds.
    func testTheLinkOfATagReadsBackAsThatTag() throws {
        for tag in ["pai", "report/weekly", "größe", "日本語", "a-b_c"] {
            let url = try XCTUnwrap(URL(string: NoteInlineTags.url(for: tag)))
            XCTAssertEqual(NoteInlineTags.tag(from: url), tag)
        }
        XCTAssertNil(NoteInlineTags.tag(from: URL(string: "https://example.com/#x")!))
    }
}
