import Foundation
import XCTest

@testable import PAIKit

/// Links to a heading — `[[#Heading]]`, `[[#Heading|alias]]` and `[[Note#Heading]]` — across the
/// scanner, the markdown they become, the URL they travel in and the lookup a tap ends in. The
/// rendering and slug cases mirror the web's `wikilinks.test.ts` and `headingSlug.test.ts`.
final class NoteHeadingLinksTests: XCTestCase {

    // MARK: - Scanner against the pattern it replaces

    private func referenceMatches(in body: String) -> [WikilinkScan.HeadingMatch] {
        let pattern = /\[\[#([^\]|\n]+)(\|[^\]\n]+)?\]\]/
        func offsets(_ r: Range<String.Index>) -> Range<Int> {
            body.distance(
                from: body.startIndex, to: r.lowerBound)..<body.distance(
                    from: body.startIndex, to: r.upperBound)
        }
        return body.matches(of: pattern).map { match in
            let whole = offsets(match.range)
            let (_, heading, alias) = match.output
            return WikilinkScan.HeadingMatch(
                start: whole.lowerBound, end: whole.upperBound,
                heading: offsets(heading.startIndex..<heading.endIndex),
                alias: alias.map { offsets($0.startIndex..<$0.endIndex) })
        }
    }

    private static func allSequences(_ fragments: [String], length: Int) -> [String] {
        var level = [""]
        var out = [""]
        for _ in 0..<length {
            level = level.flatMap { prefix in fragments.map { prefix + $0 } }
            out.append(contentsOf: level)
        }
        return out
    }

    /// A CRLF and a combining mark are one Character each, which is what the Regex sees and a
    /// UTF-16 scan would not.
    func testHeadingLinkScannerFindsExactlyWhatThePatternFinds() {
        let bodies =
            Self.allSequences(["[[#", "]]", "|", "a", "\n", "#", "[["], length: 5)
            + Self.allSequences(["[[#", "]]", "\r\n", "\u{301}", "|", "x"], length: 4)
        var disagreements: [String] = []
        for body in bodies where WikilinkScan.headingLinks(in: Array(body)) != referenceMatches(in: body) {
            disagreements.append(body.debugDescription)
            if disagreements.count == 5 { break }
        }
        XCTAssertGreaterThan(bodies.count, 15_000)
        XCTAssertEqual(disagreements, [])
    }

    func testUnterminatedHeadingLinksScanInLinearTime() {
        let body = String(repeating: "[[#a ", count: 60_000)
        let started = Date()
        XCTAssertEqual(WikilinkScan.headingLinks(in: Array(body)), [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: - Slug and link text

    func testSlugLowercasesAndCollapsesNonAlphanumericRuns() {
        XCTAssertEqual(NoteHeading.slug("Deploying to Kubernetes!"), "deploying-to-kubernetes")
        XCTAssertEqual(NoteHeading.slug("  A  b  "), "a-b")
        XCTAssertEqual(NoteHeading.slug("Überblick 2"), "überblick-2")
        XCTAssertEqual(NoteHeading.slug("---"), "section")
    }

    /// `\p{L}\p{N}` in the web's slugifier leaves marks out, so a decomposed accent splits the
    /// word the same way here.
    func testSlugTreatsACombiningMarkAsASeparator() {
        XCTAssertEqual(NoteHeading.slug("cafe\u{301}s"), "cafe-s")
    }

    func testLinkTextTakesTheLastSegmentAndRefusesBlockReferences() {
        XCTAssertEqual(NoteHeading.linkText("Setup"), "Setup")
        XCTAssertEqual(NoteHeading.linkText("Parent#Child"), "Child")
        XCTAssertEqual(NoteHeading.linkText(" Setup "), "Setup")
        XCTAssertNil(NoteHeading.linkText("^abc123"))
        XCTAssertNil(NoteHeading.linkText("Parent#"))
        XCTAssertNil(NoteHeading.linkText("  "))
    }

    // MARK: - Rendering

    private func markdown(_ body: String, names: [String: String] = [:], selfName: String? = nil) -> String {
        guard case .text(let text)? = splitBodyForRender(body, nameToId: names, selfName: selfName).first else {
            XCTFail("no text segment for \(body)")
            return ""
        }
        return text
    }

    func testAHeadingLinkBecomesAJumpWithinThePage() {
        XCTAssertEqual(
            markdown("See [[#Setup steps]].", selfName: "Trip"), "See [Setup steps](pai://note#Setup%20steps).")
    }

    func testTheAliasIsTheDisplayText() {
        XCTAssertEqual(markdown("[[#Setup|the start]]"), "[the start](pai://note#Setup)")
    }

    func testANestedHeadingPathLandsOnItsLastSegment() {
        XCTAssertEqual(markdown("[[#Parent#Child]]"), "[Child](pai://note#Child)")
    }

    func testALinkToAnotherNotesHeadingCarriesTheHeadingAfterTheId() {
        XCTAssertEqual(
            markdown("[[Other#Sub (1)]]", names: ["other": "id-9"]),
            "[Other > Sub (1)](pai://note/id-9#Sub%20%281%29)")
    }

    func testALinkNamingThisNoteIsAHeadingOfThisPage() {
        XCTAssertEqual(
            markdown("[[Trip#Packing]]", names: ["trip": "id-1"], selfName: "trip"),
            "[Trip > Packing](pai://note#Packing)")
        // Without the note's own name it is an ordinary link to the note, at the heading.
        XCTAssertEqual(
            markdown("[[Trip#Packing]]", names: ["trip": "id-1"]), "[Trip > Packing](pai://note/id-1#Packing)")
    }

    func testABlockReferenceStaysTextInsteadOfADeadJump() {
        XCTAssertEqual(markdown("[[#^abc123]]"), "^abc123")
    }

    func testAHeadingLinkInsideCodeIsNotALink() {
        let body = "`[[#Setup]]`\n```\n[[#Setup]]\n```"
        XCTAssertEqual(markdown(body), body)
    }

    func testAnUnresolvedNoteWithAHeadingIsStruckThrough() {
        XCTAssertEqual(markdown("[[Gone#Part]]"), "~~Gone > Part~~")
    }

    func testBothLinkKindsInOneBodyKeepTheirOrder() {
        XCTAssertEqual(
            markdown("[[#A]] then [[T]] then [[#B]]", names: ["t": "id-2"]),
            "[A](pai://note#A) then [T](pai://note/id-2) then [B](pai://note#B)")
    }

    // MARK: - The URL

    func testLinkURLsRoundTripThroughTheParser() throws {
        let headings = ["Setup steps", "Sub (1)", "Überblick – Ärger", "100% #1", "a/b?c=d&e", "\"quoted\" \\ &"]
        for heading in headings {
            for id in ["id-9", "a b/c", ""] {
                let url = try XCTUnwrap(URL(string: noteLinkURL(id: id, heading: heading)), "\(id) \(heading)")
                XCTAssertEqual(NoteLinkTarget.parse(url), NoteLinkTarget(id: id, heading: heading), "\(id) \(heading)")
            }
        }
        // Nothing in the URL ends a markdown destination early.
        let encoded = noteLinkURL(id: "id", heading: "a (b) \"c\" <d>")
        XCTAssertFalse(encoded.contains(where: { " ()<>\"".contains($0) }), encoded)
    }

    func testAPlainNoteLinkHasNoHeading() throws {
        let url = try XCTUnwrap(URL(string: noteLinkURL(id: "id-9")))
        XCTAssertEqual(url.absoluteString, "pai://note/id-9")
        XCTAssertEqual(NoteLinkTarget.parse(url), NoteLinkTarget(id: "id-9", heading: nil))
    }

    /// A heading link that escapes to the system still opens the right note: the deep link's own
    /// parser ignores the fragment.
    func testTheDeepLinkParserStillReadsTheNoteOfAHeadingLink() throws {
        let url = try XCTUnwrap(URL(string: noteLinkURL(id: "id-9", heading: "Setup")))
        XCTAssertEqual(DeepLink.from(url: url), .note(id: "id-9"))
        let inPage = try XCTUnwrap(URL(string: noteLinkURL(id: "", heading: "Setup")))
        XCTAssertNil(DeepLink.from(url: inPage))
    }

    func testOtherURLsAreNotNoteLinks() throws {
        for text in ["https://example.com/#x", "pai://notes", "pai://session/abc", "pai://note", "pai://note/"] {
            XCTAssertNil(NoteLinkTarget.parse(try XCTUnwrap(URL(string: text))), text)
        }
    }

    // MARK: - The jump

    func testTheFirstHeadingWithTheSameSlugIsTheTarget() {
        let body = "# Intro\n## Setup steps\ntext\n## Setup Steps!\n"
        XCTAssertEqual(NoteHeading.offset(of: "setup steps", in: body), 8)
        XCTAssertNil(NoteHeading.offset(of: "Missing", in: body))
    }

    /// A tap has to end on the heading's own block, through the same offset-to-item mapping the
    /// outline uses.
    func testAHeadingLinkLandsOnItsHeadingItem() throws {
        let body = "Intro [[#Setup]] here\n\n## Setup\n\ntext\n"
        let document = NotePreviewDocument(body: body, nameToId: [:])
        let offset = try XCTUnwrap(NoteHeading.offset(of: "Setup", in: body))
        let index = try XCTUnwrap(document.itemIndex(forCharacterOffset: offset, in: body))
        guard case .block(.heading(_, let text)) = document.items[index].kind else {
            return XCTFail("expected the heading item, got \(document.items[index].kind)")
        }
        XCTAssertEqual(String(describing: text).contains("Setup"), true)
        XCTAssertEqual(document.items.count, 3, "the link must stay inline in its paragraph")
    }
}
