import XCTest

@testable import PAIKit

/// The seams. Everything inside a segment is UIKit's job; what is tested here is the handful of
/// moments where the editor has to decide something UIKit cannot — and each of those, got wrong,
/// is a caret that jumps or a keystroke that appears to do nothing.
final class NoteEditorDocumentTests: XCTestCase {

    // MARK: Identity

    /// The single most visible failure an editor can have: rebuilding the text view being typed
    /// in sends the caret to the end. So an edit that does not change the note's shape must not
    /// change any identity.
    func testAnOrdinaryEditKeepsEverySegmentsIdentity() {
        var document = NoteEditorDocument(source: "para\n\n```\ncode\n```\n\ntail\n")
        let before = document.items.map(\.id)
        _ = document.edit(id: before[0], displayText: "para edited")
        XCTAssertEqual(document.items.map(\.id), before)
    }

    /// And it must not move the caret either — a caret target means "the view was rebuilt, put
    /// the caret back", so returning one for a plain keystroke would cause the very jump it is
    /// meant to repair.
    func testAnOrdinaryEditAsksForNoCaretMove() {
        var document = NoteEditorDocument(source: "para\n\ntail\n")
        XCTAssertNil(document.edit(id: document.items[0].id, displayText: "para edited"))
    }

    /// A segment that survives an edit elsewhere keeps its identity even though its position
    /// moved, so its view is not thrown away and rebuilt.
    func testASegmentKeepsItsIdentityWhenOneAboveItIsRestructured() {
        var document = NoteEditorDocument(source: "top\n\n```\nx\n```\n\ntail\n")
        let tailID = document.items.last!.id
        _ = document.edit(id: document.items[0].id, displayText: "```\ntop\n```")
        XCTAssertTrue(document.items.contains { $0.id == tailID }, "the untouched tail was rebuilt")
    }

    // MARK: Structure follows the text

    func testTypingAFenceTurnsAParagraphIntoACodeBlock() {
        var document = NoteEditorDocument(source: "hello\n")
        _ = document.edit(id: document.items[0].id, displayText: "```\nhello\n```")
        XCTAssertEqual(document.items.map(\.kind), [.codeBlock])
    }

    /// The caret has to follow the text into its new home. Left behind, the next keystroke lands
    /// in a segment that no longer exists.
    func testTheCaretFollowsTextIntoItsNewSegment() {
        var document = NoteEditorDocument(source: "hello\n")
        let caret = document.edit(id: document.items[0].id, displayText: "```\nhello\n```")
        XCTAssertEqual(caret?.itemID, document.items[0].id)
    }

    func testDeletingAFenceTurnsACodeBlockBackIntoProse() {
        var document = NoteEditorDocument(source: "```\nhello\n```\n")
        _ = document.edit(id: document.items[0].id, displayText: "hello")
        XCTAssertEqual(document.items.map(\.kind), [.prose])
    }

    // MARK: Backspace at a boundary

    /// Before a code block the boundary is its fences, so this unwraps it — and the contents
    /// become prose that fuses with what came before. Dropping only the blank line above would
    /// leave the block standing and appear to do nothing at all.
    func testBackspaceAtTheStartOfACodeBlockUnwrapsIt() {
        var document = NoteEditorDocument(source: "before\n\n```\ncode\n```\n\nafter\n")
        XCTAssertEqual(document.items.count, 3)
        _ = document.mergeBackward(from: document.items[1].id)
        XCTAssertEqual(document.items.map(\.kind), [.prose])
        XCTAssertFalse(document.source.contains("```"), "a fence survived the unwrap")
        XCTAssertTrue(document.source.contains("code"), "the block's contents were lost")
    }

    /// Both fences go together. A lone closing fence is an opening one to the next parse, which
    /// would turn everything below it into code.
    func testUnwrappingNeverLeavesALoneFenceBehind() {
        var document = NoteEditorDocument(source: "a\n\n```\nx\n```\n\nb\n\n```\ny\n```\n")
        _ = document.mergeBackward(from: document.items[1].id)
        XCTAssertEqual(document.items.filter { $0.kind == .codeBlock }.count, 1)
    }

    /// Before ordinary prose the boundary is only the blank line, so only the blank line goes.
    /// The two regions still cannot become one — a fence between them is a fence.
    func testBackspaceAfterACodeBlockRemovesOnlyTheBlankLine() {
        var document = NoteEditorDocument(source: "```\nc\n```\n\nafter\n")
        _ = document.mergeBackward(from: document.items[1].id)
        XCTAssertEqual(document.source, "```\nc\n```\nafter\n")
    }

    /// Consecutive paragraphs are one segment, so there is no boundary inside prose to merge
    /// across — UIKit already handles Backspace there, and this must not interfere.
    func testProseHasNoInternalBoundaryToMergeAcross() {
        var document = NoteEditorDocument(source: "before\n\nafter\n")
        XCTAssertEqual(document.items.count, 1)
        XCTAssertNil(document.mergeBackward(from: document.items[0].id))
    }

    /// Where the caret lands is the whole feel of the operation: at the join, so typing carries
    /// on from the same place rather than from an end the reader did not ask for.
    func testTheCaretLandsAtTheJoinNotAtAnEnd() {
        var document = NoteEditorDocument(source: "before\n\n```\ncode\n```\n")
        guard let caret = document.mergeBackward(from: document.items[1].id) else {
            return XCTFail("unwrapping the block did nothing")
        }
        guard let index = document.index(of: caret.itemID) else { return XCTFail("caret names no segment") }
        XCTAssertEqual(caret.offset, "before".utf16.count)
        XCTAssertTrue(document.items[index].displayText.hasPrefix("before"))
    }

    func testMergingAcrossACodeBlockPutsTheCaretAtTheEndOfWhatCameBefore() {
        var document = NoteEditorDocument(source: "intro\n\n```\nc\n```\n\ntail\n")
        guard let caret = document.mergeBackward(from: document.items[2].id) else {
            return XCTFail("merging the tail did nothing")
        }
        guard let index = document.index(of: caret.itemID) else { return XCTFail("caret names no segment") }
        let landing = document.items[index].displayText
        XCTAssertLessThanOrEqual(caret.offset, landing.utf16.count, "caret is past the end of its segment")
    }

    /// Nothing to join to. Swallowing the keystroke is right; deleting a character the reader
    /// cannot see is not.
    func testBackspaceAtTheVeryStartOfTheNoteDoesNothing() {
        var document = NoteEditorDocument(source: "text\n")
        let before = document.source
        XCTAssertNil(document.mergeBackward(from: document.items[0].id))
        XCTAssertEqual(document.source, before)
    }

    /// The separator is what the boundary was made of. Left behind, Backspace visibly does
    /// nothing and the reader presses it again.
    func testMergingRemovesTheSeparatorTheBoundaryWasMadeOf() {
        var document = NoteEditorDocument(source: "```\nc\n```\n\ntail\n")
        _ = document.mergeBackward(from: document.items[1].id)
        XCTAssertFalse(document.source.contains("```\n\ntail"), "the blank line survived the merge")
    }

    // MARK: The file

    /// The note is written back byte-for-byte. Everything above is only safe because of this.
    func testTheSourceIsUnchangedUntilSomethingIsEdited() {
        let source = "---\nid: 1\n---\n\n# Title\n\n```sh\necho\n```\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nend\n"
        XCTAssertEqual(NoteEditorDocument(source: source).source, source)
    }

    func testAnEditChangesOnlyWhatWasEdited() {
        let source = "# Title\n\n```sh\necho\n```\n\nend\n"
        var document = NoteEditorDocument(source: source)
        let last = document.items.last!
        XCTAssertEqual(last.displayText, "end\n", "the last prose region shows its own trailing newline")
        _ = document.edit(id: last.id, displayText: "the end\n")
        XCTAssertEqual(document.source, "# Title\n\n```sh\necho\n```\n\nthe end\n")
    }

    /// An empty note still needs somewhere to type. With no segments the editor shows no text
    /// view at all, which reads as a note that failed to load.
    func testAnEmptyNoteStillHasOnePlaceToType() {
        let document = NoteEditorDocument(source: "")
        XCTAssertEqual(document.items.count, 1)
        XCTAssertEqual(document.items[0].kind, .prose)
        XCTAssertEqual(document.source, "")
    }

    func testEditingAnUnknownSegmentChangesNothing() {
        var document = NoteEditorDocument(source: "a\n")
        let before = document.source
        XCTAssertNil(document.edit(id: UUID(), displayText: "b"))
        XCTAssertEqual(document.source, before)
    }
}

/// Turning an offset into the whole note into a place in one region. The outline and the in-note
/// search both hand over a Character offset into the body, and a text view wants a UTF-16 offset
/// into its own region — get either half wrong and every jump lands somewhere plausible and wrong.
final class NoteEditorDocumentLocateTests: XCTestCase {

    private let note = "# One\n\n```sh\necho hi\n```\n\nafter the block\n"

    func testAnOffsetInTheFirstRegionStaysThere() {
        let document = NoteEditorDocument(source: note)
        let target = document.locate(characterOffset: 2)
        XCTAssertEqual(target?.itemID, document.items[0].id)
        XCTAssertEqual(target?.offset, 2)
    }

    /// The blank lines between two regions belong to neither on screen — the editor carries them
    /// invisibly. An offset aimed at one has to land at the start of what follows rather than at a
    /// negative position inside it.
    func testAnOffsetInTheSeparatorLandsAtTheStartOfTheNextRegion() {
        let document = NoteEditorDocument(source: note)
        // The blank line immediately after the closing fence: separator, not content.
        let afterFence = note.range(of: "```\n\n")!.upperBound
        let target = document.locate(characterOffset: note.distance(from: note.startIndex, to: afterFence) - 1)
        XCTAssertEqual(target?.itemID, document.items[2].id)
        XCTAssertEqual(target?.offset, 0)
    }

    func testAnOffsetPastTheEndClampsToTheLastRegion() {
        let document = NoteEditorDocument(source: note)
        let target = document.locate(characterOffset: 9_999)
        XCTAssertEqual(target?.itemID, document.items.last?.id)
        XCTAssertEqual(target?.offset, document.items.last?.displayText.utf16.count)
    }

    /// Characters in, UTF-16 out. The two agree on ASCII and diverge on the first emoji, so a test
    /// written in English proves nothing about the conversion at all.
    func testAnOffsetPastAnEmojiIsConvertedToUtf16() {
        let document = NoteEditorDocument(source: "🎯🎯abc\n")
        // Three Characters in: past both emoji, before "a".
        let target = document.locate(characterOffset: 2)
        XCTAssertEqual(target?.offset, 4, "two emoji are two Characters and four UTF-16 units")
    }
}

/// A note that ends in a block has no wrapping region under it, so there is nowhere to type at all.
final class NoteEditorDocumentTrailingProseTests: XCTestCase {

    func testANoteEndingInACodeBlockGainsAPlaceToType() {
        var document = NoteEditorDocument(source: "intro\n\n```sh\necho\n```\n")
        XCTAssertEqual(document.items.last?.kind, .codeBlock)

        let target = document.appendTrailingProse()

        XCTAssertEqual(document.items.last?.kind, .prose)
        XCTAssertEqual(target?.itemID, document.items.last?.id)
        XCTAssertEqual(document.items.last?.displayText, "", "an empty paragraph, not a visible blank line")
        XCTAssertEqual(document.source, "intro\n\n```sh\necho\n```\n\n")
    }

    /// A table at the very end of a file has no trailing newline of its own, so the separator has
    /// to supply the line break as well as the blank line.
    func testATableAtTheVeryEndGainsAPlaceToType() {
        var document = NoteEditorDocument(source: "| a |\n|---|\n| 1 |")
        let target = document.appendTrailingProse()
        XCTAssertEqual(document.items.map(\.kind), [.table, .prose])
        XCTAssertEqual(target?.offset, 0)
        XCTAssertEqual(document.source, "| a |\n|---|\n| 1 |\n\n")
    }

    func testANoteThatAlreadyEndsInProseIsLeftAlone() {
        var document = NoteEditorDocument(source: "```\na\n```\n\ntail\n")
        let before = document.source
        XCTAssertNil(document.appendTrailingProse())
        XCTAssertEqual(document.source, before)
    }
}

/// Which region owns the newlines at its end.
///
/// Everywhere but the very bottom of a note those newlines are the gap between two regions and the
/// editor hides them, which is what keeps the file byte-exact through an edit. At the bottom there
/// is nothing for them to separate, and hiding them there is the bug this covers: the text view
/// holds the paragraph break that was just typed, the segment absorbs it into a separator, and the
/// next update resets the view to the line it was already on. Return appears to do nothing — on a
/// brand new note, where the caret is always at the end, it appears to do nothing ever.
final class NoteEditorDocumentTrailingNewlineTests: XCTestCase {

    func testReturnAtTheEndOfAFreshNoteProducesANewline() {
        var document = NoteEditorDocument(source: "")
        _ = document.edit(id: document.items[0].id, displayText: "okok")
        _ = document.edit(id: document.items[0].id, displayText: "okok\n")
        XCTAssertEqual(document.source, "okok\n")
        XCTAssertEqual(document.items[0].displayText, "okok\n", "the view would be reset to the line above")
    }

    func testReturnAtTheEndOfAnExistingNoteProducesANewline() {
        var document = NoteEditorDocument(source: "a\n")
        XCTAssertEqual(document.items[0].displayText, "a\n")
        _ = document.edit(id: document.items[0].id, displayText: "a\n\n")
        XCTAssertEqual(document.source, "a\n\n")
        XCTAssertEqual(document.items[0].displayText, "a\n\n")
    }

    /// The other half of the rule, and the reason it is scoped to the last region rather than
    /// applied everywhere: a separator that became visible mid-note could be deleted, and deleting
    /// the blank line above a fence joins it to the paragraph.
    func testARegionBeforeAnotherStillHidesItsSeparator() {
        let document = NoteEditorDocument(source: "text\n\n```\nx\n```\n")
        XCTAssertEqual(document.items[0].displayText, "text")
    }

    /// A block at the bottom keeps its separator hidden too — shown, it would draw an empty line
    /// inside the box below the closing fence, and the height arithmetic would count it.
    func testATrailingCodeBlockDoesNotShowItsSeparator() {
        let document = NoteEditorDocument(source: "text\n\n```\nx\n```\n")
        XCTAssertEqual(document.items[1].displayText, "```\nx\n```")
    }

    /// The paragraph appended under a trailing block is itself the last region, so Return works in
    /// it for the same reason it works anywhere else at the bottom.
    func testTheParagraphAppendedUnderABlockCanTakeAParagraphBreak() {
        var document = NoteEditorDocument(source: "```\nx\n```\n")
        guard let target = document.appendTrailingProse() else {
            return XCTFail("no paragraph was appended under the block")
        }
        _ = document.edit(id: target.itemID, displayText: "hi\n")
        XCTAssertEqual(document.source, "```\nx\n```\n\nhi\n")
    }
}
