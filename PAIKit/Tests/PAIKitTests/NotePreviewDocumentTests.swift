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
            guard case .block(.heading(_, let text)) = document.items[index].kind else {
                return XCTFail("expected a heading item for '\(entry.text)', got \(document.items[index].kind)")
            }
            XCTAssertEqual(text.plainText, entry.text)
        }
    }

    func testEmbedBecomesItsOwnItemSeparateFromSurroundingParagraphs() {
        let body = "Before text.\n\n![[attachments/photo.png]]\n\nAfter text."
        let document = NotePreviewDocument(body: body, nameToId: [:])
        XCTAssertEqual(document.items.count, 3)

        guard case .block(.paragraph(let before)) = document.items[0].kind else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(before.plainText, "Before text.")

        guard case .embed(let target, let alias) = document.items[1].kind else {
            return XCTFail("expected an embed")
        }
        XCTAssertEqual(target, "attachments/photo.png")
        XCTAssertNil(alias)

        guard case .block(.paragraph(let after)) = document.items[2].kind else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(after.plainText, "After text.")
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
        guard case .block(.heading(_, let text)) = document.items[index].kind else {
            return XCTFail("expected a heading item, got \(document.items[index].kind)")
        }
        XCTAssertEqual(text.plainText, "Heading After Embed")
    }

    func testWikilinkInsideAParagraphIsStillResolved() {
        let body = "See [[Target]] for more."
        let document = NotePreviewDocument(body: body, nameToId: ["target": "note-123"])
        XCTAssertEqual(document.items.count, 1)
        guard case .block(.paragraph(let text)) = document.items[0].kind else {
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
        guard case .block(.heading(_, let text)) = document.items[index].kind else {
            return XCTFail("expected a heading item, got \(document.items[index].kind)")
        }
        XCTAssertEqual(text.plainText, "Heading")
    }

    /// The exact shape that reached Freddy's own vault: a checklist item with an image pasted
    /// directly below it, no blank line in between — Obsidian's lazy continuation would otherwise
    /// fold the embed into the list item's own paragraph, where nothing downstream ever looks for
    /// one, and it rendered as the literal placeholder text instead of an image.
    func testEmbedImmediatelyAfterAListItemStillBecomesItsOwnEmbed() {
        let body =
            "- [x] item text\n![[attachments/Pasted image 1.png]]\nmore text\n![[attachments/Pasted image 2.png]]\n"
        let document = NotePreviewDocument(body: body, nameToId: [:])

        guard case .block(.list) = document.items[0].kind else {
            return XCTFail("expected the checklist item as its own block, got \(document.items[0].kind)")
        }
        XCTAssertEqual(document.items[0].startLine, 1)

        guard case .embed(let target1, _) = document.items[1].kind else {
            return XCTFail("expected an embed, got \(document.items[1].kind)")
        }
        XCTAssertEqual(target1, "attachments/Pasted image 1.png")
        XCTAssertEqual(document.items[1].startLine, 2)

        guard case .block(.paragraph(let text)) = document.items[2].kind else {
            return XCTFail("expected the continuation text as its own paragraph, got \(document.items[2].kind)")
        }
        XCTAssertEqual(text.plainText, "more text")
        XCTAssertEqual(document.items[2].startLine, 3)

        guard case .embed(let target2, _) = document.items[3].kind else {
            return XCTFail("expected a second embed, got \(document.items[3].kind)")
        }
        XCTAssertEqual(target2, "attachments/Pasted image 2.png")
        XCTAssertEqual(document.items[3].startLine, 4)
    }

    /// A shape seen in a real vault: a plain (non-embed) wikilink to a real attachment must
    /// resolve to an attachment link rather than fall through to the dead-target strikethrough
    /// branch — a note carrying `[[attachments/repo.codelocal]]` rendered struck through as
    /// though the file were missing, while the web (which resolves a wikilink against the
    /// attachment index, not just note names) correctly showed a download chip.
    func testWikilinkToARealAttachmentBecomesAnAttachmentLinkItemNotStrikethrough() {
        let body = "My Repo Stuff [[attachments/repo.codelocal]]"
        let attachments = [
            NoteAttachmentRecord(
                relPath: "attachments/repo.codelocal", basename: "repo.codelocal", ext: "codelocal",
                sizeBytes: 1, mtimeMs: 0, linkCount: 1)
        ]
        let document = NotePreviewDocument(
            body: body, nameToId: [:], attachmentIndex: buildAttachmentIndex(attachments))
        XCTAssertEqual(document.items.count, 2)

        guard case .block(.paragraph(let text)) = document.items[0].kind else {
            return XCTFail("expected the leading text as its own paragraph, got \(document.items[0].kind)")
        }
        XCTAssertEqual(text.plainText, "My Repo Stuff")
        XCTAssertFalse(
            text.runs.contains { $0.style.contains(.strikethrough) },
            "the attachment link text must not be struck through")

        guard case .attachmentLink(let target) = document.items[1].kind else {
            return XCTFail("expected an attachment link, got \(document.items[1].kind)")
        }
        XCTAssertEqual(target, "attachments/repo.codelocal")
    }

    /// A bare filename (no `attachments/` prefix) still resolves — the basename fallback step,
    /// checked only after a note-by-name match fails, mirroring the web and the pod's own
    /// `note_links_resolved` three-step order.
    func testWikilinkToAnAttachmentByBareBasenameStillResolves() {
        let body = "[[repo.codelocal]]"
        let attachments = [
            NoteAttachmentRecord(
                relPath: "attachments/repo.codelocal", basename: "repo.codelocal", ext: "codelocal",
                sizeBytes: 1, mtimeMs: 0, linkCount: 1)
        ]
        let document = NotePreviewDocument(
            body: body, nameToId: [:], attachmentIndex: buildAttachmentIndex(attachments))
        XCTAssertEqual(document.items.count, 1)
        guard case .attachmentLink(let target) = document.items[0].kind else {
            return XCTFail("expected an attachment link, got \(document.items[0].kind)")
        }
        XCTAssertEqual(target, "attachments/repo.codelocal")
    }

    /// A wikilink that resolves to BOTH a note and an attachment by full path must resolve to the
    /// attachment — `note_links_resolved`'s own priority order, which the web mirrors.
    func testWikilinkPrefersAnExactAttachmentPathMatchOverANoteName() {
        let body = "[[attachments/shared-name]]"
        let attachments = [
            NoteAttachmentRecord(
                relPath: "attachments/shared-name", basename: "shared-name", ext: "",
                sizeBytes: 1, mtimeMs: 0, linkCount: 1)
        ]
        // "shared-name" is the basename step's lookup key — the one a note match would be found
        // under if the attachment's full-path match (checked first) did not already win.
        let document = NotePreviewDocument(
            body: body, nameToId: ["shared-name": "note-should-lose"],
            attachmentIndex: buildAttachmentIndex(attachments))
        XCTAssertEqual(document.items.count, 1)
        guard case .attachmentLink(let target) = document.items[0].kind else {
            return XCTFail("expected an attachment link, got \(document.items[0].kind)")
        }
        XCTAssertEqual(target, "attachments/shared-name")
    }

    /// Several embeds on consecutive lines, with no blank line between them, would otherwise cmark
    /// as one paragraph carrying every placeholder at once — each must still land as its own item.
    func testConsecutiveEmbedsWithNoBlankLineEachBecomeTheirOwnItem() {
        let body = "![[attachments/a.png]]\n![[attachments/b.png]]\n![[attachments/c.png]]\n"
        let document = NotePreviewDocument(body: body, nameToId: [:])
        XCTAssertEqual(document.items.count, 3)
        for (index, expected) in ["attachments/a.png", "attachments/b.png", "attachments/c.png"].enumerated() {
            guard case .embed(let target, _) = document.items[index].kind else {
                return XCTFail("expected an embed at \(index), got \(document.items[index].kind)")
            }
            XCTAssertEqual(target, expected)
            XCTAssertEqual(document.items[index].startLine, index + 1)
        }
    }
}
