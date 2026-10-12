import XCTest
@testable import PAIKit

/// ``NotePreviewDocument`` exists to let a jump from the outline or from in-note search land on
/// the right rendered item — these tests are about that alignment surviving a refactor of how
/// items are built, not about restating what the parser already does.
final class NotePreviewDocumentTests: XCTestCase {

    func testItemIndexPicksTheBlockAnOffsetFallsIn() {
        let body = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        let document = NotePreviewDocument(body: body, nameToId: [:])
        XCTAssertEqual(document.items.count, 3)

        let secondOffset = body.distance(from: body.startIndex, to: body.range(of: "Second")!.lowerBound)
        let thirdOffset = body.distance(from: body.startIndex, to: body.range(of: "Third")!.lowerBound)
        XCTAssertEqual(document.itemIndex(forCharacterOffset: 0, in: body), 0)
        XCTAssertEqual(document.itemIndex(forCharacterOffset: secondOffset, in: body), 1)
        XCTAssertEqual(document.itemIndex(forCharacterOffset: thirdOffset, in: body), 2)
    }

    /// The integration this type exists for: every heading ``parseOutline(_:)`` finds must land,
    /// through ``NotePreviewDocument/itemIndex(forCharacterOffset:in:)``, on the matching
    /// `.heading` item — a per-child re-parse that silently dropped or reordered an item would
    /// still pass a test that only counted items, so this checks each offset resolves to a
    /// heading whose own text agrees with the outline's.
    func testEveryOutlineHeadingResolvesToItsOwnHeadingItem() {
        let body = "# Title\n\nSome intro text.\n\n## Section Two\n\nMore text here."
        let outline = parseOutline(body)
        XCTAssertEqual(outline.count, 2)

        let document = NotePreviewDocument(body: body, nameToId: [:])
        for entry in outline {
            guard let index = document.itemIndex(forCharacterOffset: entry.offset, in: body) else {
                return XCTFail("no item for offset \(entry.offset)")
            }
            guard case .heading(_, let text) = document.items[index].block else {
                return XCTFail("expected a heading item for '\(entry.text)', got \(document.items[index].block)")
            }
            XCTAssertEqual(text.plainText, entry.text)
        }
    }

    /// A heading after an embed line has to land on the same source line either way — proves the
    /// placeholder substitution never shifts line numbers, which is what lets ``itemIndex``
    /// trust a source line computed against the *original* body.
    func testHeadingAfterAnEmbedKeepsItsSourceLine() {
        let body = "![[attachments/x.png]]\n\n# Heading After Embed"
        let outline = parseOutline(body)
        XCTAssertEqual(outline.count, 1)

        let document = NotePreviewDocument(body: body, nameToId: [:])
        guard let index = document.itemIndex(forCharacterOffset: outline[0].offset, in: body) else {
            return XCTFail("no item for the heading's own offset")
        }
        guard case .heading(_, let text) = document.items[index].block else {
            return XCTFail("expected a heading item, got \(document.items[index].block)")
        }
        XCTAssertEqual(text.plainText, "Heading After Embed")
    }

    func testWikilinkInsideAParagraphIsStillResolved() {
        let body = "See [[Target]] for more."
        let document = NotePreviewDocument(body: body, nameToId: ["target": "note-123"])
        XCTAssertEqual(document.items.count, 1)
        guard case .paragraph(let text) = document.items[0].block else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertTrue(
            text.runs.contains { $0.destination?.contains("note-123") == true },
            "expected a run linking to note-123, got \(text.runs)")
    }

    /// `SourceLocation.column` counts UTF-8 bytes, not Characters — the exact trap this type
    /// avoids by only ever reading `.line`. A multi-byte character earlier on the line must not
    /// throw off which line a later offset is counted as being on.
    func testLineNumberIsCorrectAfterAMultiByteCharacter() {
        let body = "🎉 hello\n# Heading\nworld"
        let headingOffset = body.distance(from: body.startIndex, to: body.range(of: "# Heading")!.lowerBound)
        XCTAssertEqual(lineNumber(ofCharacterOffset: headingOffset, in: body), 2)

        let document = NotePreviewDocument(body: body, nameToId: [:])
        guard let index = document.itemIndex(forCharacterOffset: headingOffset, in: body) else {
            return XCTFail("no item for the heading's own offset")
        }
        guard case .heading(_, let text) = document.items[index].block else {
            return XCTFail("expected a heading item, got \(document.items[index].block)")
        }
        XCTAssertEqual(text.plainText, "Heading")
    }

    /// A body with an attachment on every line of a nested list: each attachment link inside a
    /// tab-indented item. Parsed apart at the attachments, the text after one starts with a
    /// tab-indented line and reads as a code block, and the list breaks in two.
    private let attachmentList = """
        - **Bike one**, black, M
        	- Parts: [Parts list](https://example.org/a)
        	- Papers: [[attachments/Bike papers/one.pdf]]
        - **Bike two**
        	- Papers: [[attachments/Bike papers/two.pdf|Second papers.pdf]]
        	- Paid: [Purchases](https://example.org/b)
        - The column **Status** says where each one is.
        """

    private func attachments(_ paths: String...) -> AttachmentIndex {
        buildAttachmentIndex(
            paths.map {
                NoteAttachmentRecord(
                    relPath: $0, basename: String($0.split(separator: "/").last!), ext: "pdf", sizeBytes: 1,
                    mtimeMs: 0, linkCount: 1)
            })
    }

    /// The lines a paragraph draws, with images as blocks the way the preview draws them.
    private func lines(_ text: InlineText, in document: NotePreviewDocument) -> [NotePreviewInline.Line]? {
        NotePreviewInline.lines(
            of: text, attachments: document.attachments,
            drawsAsBlock: { $0.mode == .embed && $0.target.hasSuffix(".png") })
    }

    private func containsCodeBlock(_ blocks: [MarkdownBlock]) -> Bool {
        blocks.contains { block in
            switch block {
            case .codeBlock: return true
            case .list(let list): return list.items.contains { containsCodeBlock($0.blocks) }
            case .blockQuote(let nested): return containsCodeBlock(nested)
            default: return false
            }
        }
    }

    func testAnAttachmentInsideANestedListItemLeavesTheListWhole() throws {
        let document = NotePreviewDocument(
            body: attachmentList, nameToId: [:],
            attachmentIndex: attachments("attachments/Bike papers/one.pdf", "attachments/Bike papers/two.pdf"))

        XCTAssertEqual(document.items.count, 1, "one list, got \(document.items.map(\.block))")
        XCTAssertFalse(containsCodeBlock(document.items.map(\.block)))
        guard case .list(let list) = document.items[0].block else {
            return XCTFail("expected a list, got \(document.items[0].block)")
        }
        XCTAssertEqual(list.items.count, 3)

        guard case .list(let nested) = list.items[1].blocks.last, nested.items.count == 2,
            case .paragraph(let papers) = nested.items[0].blocks.first,
            case .paragraph(let paid) = nested.items[1].blocks.first
        else { return XCTFail("expected the second bike's two items, got \(list.items[1].blocks)") }

        let papersLines = try XCTUnwrap(lines(papers, in: document))
        XCTAssertEqual(
            papersLines,
            [
                .flow([
                    .text(InlineText(runs: [InlineRun(text: "Papers:")])),
                    .attachment(
                        NotePreviewAttachment(
                            target: "attachments/Bike papers/two.pdf", mode: .link, label: "Second papers.pdf")),
                ])
            ])
        XCTAssertNil(lines(paid, in: document), "a paragraph without attachments draws as plain text")
        XCTAssertEqual(paid.plainText, "Paid: Purchases")
    }

    /// A task box on an item holding an attachment, with a nested task after it: both boxes are
    /// drawn from the one parse the body's own marks come from, so both stay tickable.
    func testTaskBoxesAroundAnAttachmentStayTickable() {
        let body = "- [ ] send [[attachments/form.pdf]]\n\t- [x] signed\n"
        let document = NotePreviewDocument(
            body: body, nameToId: [:], attachmentIndex: attachments("attachments/form.pdf"))
        XCTAssertEqual(document.taskMarks.map(\.checked), [false, true])
    }

    /// An image pasted below a checklist item with no blank line between them continues that item
    /// (as in Obsidian and the web): it draws inside the item as an image, the text after it too.
    func testEmbedImmediatelyAfterAListItemDrawsInsideThatItem() throws {
        let body =
            "- [x] item text\n![[attachments/Pasted image 1.png]]\nmore text\n![[attachments/Pasted image 2.png]]\n"
        let document = NotePreviewDocument(body: body, nameToId: [:])

        XCTAssertEqual(document.items.count, 1)
        guard case .list(let list) = document.items[0].block, case .paragraph(let text) = list.items[0].blocks.first
        else { return XCTFail("expected the checklist item, got \(document.items[0].block)") }
        XCTAssertEqual(
            try XCTUnwrap(lines(text, in: document)),
            [
                .flow([.text(InlineText(runs: [InlineRun(text: "item text")]))]),
                .block(NotePreviewAttachment(target: "attachments/Pasted image 1.png", mode: .embed)),
                .flow([.text(InlineText(runs: [InlineRun(text: "more text")]))]),
                .block(NotePreviewAttachment(target: "attachments/Pasted image 2.png", mode: .embed)),
            ])
        XCTAssertEqual(document.taskMarks.count, 1)
    }

    func testEmbedOnItsOwnLineDrawsAsAnImageBetweenItsNeighbours() throws {
        let body = "Before text.\n\n![[attachments/photo.png]]\n\nAfter text."
        let document = NotePreviewDocument(body: body, nameToId: [:])
        XCTAssertEqual(document.items.map(\.startLine), [1, 3, 5])
        guard document.items.count == 3, case .paragraph(let embed) = document.items[1].block else {
            return XCTFail("expected the embed's paragraph, got \(document.items.map(\.block))")
        }
        XCTAssertEqual(
            try XCTUnwrap(lines(embed, in: document)),
            [.block(NotePreviewAttachment(target: "attachments/photo.png", mode: .embed))])
    }

    /// Several embeds on consecutive lines are one paragraph to the parser; each still draws as
    /// its own image, in order.
    func testConsecutiveEmbedsWithNoBlankLineEachDrawAsTheirOwnImage() throws {
        let body = "![[attachments/a.png]]\n![[attachments/b.png]]\n![[attachments/c.png]]\n"
        let document = NotePreviewDocument(body: body, nameToId: [:])
        guard case .paragraph(let text) = document.items.first?.block else {
            return XCTFail("expected one paragraph, got \(document.items.map(\.block))")
        }
        XCTAssertEqual(
            try XCTUnwrap(lines(text, in: document)),
            ["a", "b", "c"].map { .block(NotePreviewAttachment(target: "attachments/\($0).png", mode: .embed)) })
    }

    /// A non-image embed is a chip in its line of text, not a row of its own.
    func testANonImageEmbedFlowsWithItsText() throws {
        let document = NotePreviewDocument(body: "See ![[attachments/plan.pdf]] first", nameToId: [:])
        guard case .paragraph(let text) = document.items.first?.block else {
            return XCTFail("expected a paragraph, got \(document.items.map(\.block))")
        }
        XCTAssertEqual(
            try XCTUnwrap(lines(text, in: document)),
            [
                .flow([
                    .text(InlineText(runs: [InlineRun(text: "See")])),
                    .attachment(NotePreviewAttachment(target: "attachments/plan.pdf", mode: .embed)),
                    .text(InlineText(runs: [InlineRun(text: "first")])),
                ])
            ])
    }

    /// A link the note itself writes with the placeholder scheme names no attachment when the
    /// index is out of range, and stays a link.
    func testAPlaceholderSchemeLinkWithNoSuchAttachmentStaysText() {
        let document = NotePreviewDocument(body: "[odd](pai-attachment://7)", nameToId: [:])
        guard case .paragraph(let text) = document.items.first?.block else {
            return XCTFail("expected a paragraph, got \(document.items.map(\.block))")
        }
        XCTAssertNil(lines(text, in: document))
    }

    /// A shape seen in a real vault: a plain (non-embed) wikilink to a real attachment must
    /// resolve to an attachment rather than fall through to the dead-target strikethrough
    /// branch — a note carrying `[[attachments/repo.codelocal]]` rendered struck through as
    /// though the file were missing, while the web (which resolves a wikilink against the
    /// attachment index, not just note names) correctly showed a download chip.
    func testWikilinkToARealAttachmentBecomesAnAttachmentChipNotStrikethrough() throws {
        let body = "My Repo Stuff [[attachments/repo.codelocal]]"
        let document = NotePreviewDocument(
            body: body, nameToId: [:], attachmentIndex: attachments("attachments/repo.codelocal"))
        guard case .paragraph(let text) = document.items.first?.block else {
            return XCTFail("expected a paragraph, got \(document.items.map(\.block))")
        }
        XCTAssertFalse(
            text.runs.contains { $0.style.contains(.strikethrough) },
            "the attachment link text must not be struck through")
        XCTAssertEqual(
            try XCTUnwrap(lines(text, in: document)),
            [
                .flow([
                    .text(InlineText(runs: [InlineRun(text: "My Repo Stuff")])),
                    .attachment(NotePreviewAttachment(target: "attachments/repo.codelocal", mode: .link)),
                ])
            ])
    }

    /// A bare filename (no `attachments/` prefix) still resolves — the basename fallback step,
    /// checked only after a note-by-name match fails, mirroring the web and the pod's own
    /// `note_links_resolved` three-step order.
    func testWikilinkToAnAttachmentByBareBasenameStillResolves() {
        let document = NotePreviewDocument(
            body: "[[repo.codelocal]]", nameToId: [:], attachmentIndex: attachments("attachments/repo.codelocal"))
        XCTAssertEqual(document.attachments.map(\.target), ["attachments/repo.codelocal"])
    }

    /// A wikilink that resolves to BOTH a note and an attachment by full path must resolve to the
    /// attachment — `note_links_resolved`'s own priority order, which the web mirrors.
    func testWikilinkPrefersAnExactAttachmentPathMatchOverANoteName() {
        // "shared-name" is the basename step's lookup key — the one a note match would be found
        // under if the attachment's full-path match (checked first) did not already win.
        let document = NotePreviewDocument(
            body: "[[attachments/shared-name]]", nameToId: ["shared-name": "note-should-lose"],
            attachmentIndex: attachments("attachments/shared-name"))
        XCTAssertEqual(document.attachments.map(\.target), ["attachments/shared-name"])
    }
}
