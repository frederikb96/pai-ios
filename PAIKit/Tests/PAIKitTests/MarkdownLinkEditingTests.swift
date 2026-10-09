import Foundation
import XCTest

@testable import PAIKit

/// The link button's prefill and result. The draft and format cases mirror the web's
/// `linkDraftAt` / `formatMarkdownLink` suites so the two clients agree on what the button does.
final class MarkdownLinkEditingTests: XCTestCase {

    private func draft(_ text: String, _ start: Int, _ end: Int? = nil) -> MarkdownLinkDraft {
        MarkdownLinkEditing.draft(in: text, selection: NSRange(location: start, length: (end ?? start) - start))
    }

    private func expect(
        _ draft: MarkdownLinkDraft, text: String, url: String, from: Int, to: Int,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            draft, MarkdownLinkDraft(text: text, url: url, range: NSRange(location: from, length: to - from)),
            file: file, line: line)
    }

    // MARK: draft

    func testAPlainSelectionBecomesTheLinkText() {
        expect(draft("see Brotzeit here", 4, 12), text: "Brotzeit", url: "", from: 4, to: 12)
    }

    func testASelectedAddressBecomesTheUrl() {
        expect(
            draft("go https://example.com/a now", 3, 24), text: "", url: "https://example.com/a", from: 3, to: 24)
    }

    func testTheLinkTheCaretSitsInIsEditedInPlace() {
        expect(
            draft("x [Photos](https://p.example/s) y", 5), text: "Photos", url: "https://p.example/s", from: 2,
            to: 31)
    }

    func testABareUrlUnderTheCaretIsEdited() {
        expect(
            draft("Aufnahmen: https://cloud.example/s/r5 end", 20), text: "", url: "https://cloud.example/s/r5",
            from: 11, to: 37)
    }

    func testAnImageIsLeftAlone() {
        expect(draft("![alt](pic.png)", 3), text: "", url: "", from: 3, to: 3)
    }

    func testNothingLinkLikeInsertsAtTheCaret() {
        expect(draft("plain", 2), text: "", url: "", from: 2, to: 2)
    }

    func testAnAngleBracketedUrlLosesItsBrackets() {
        expect(
            draft("[a](<https://x.example/a (b)>)", 1), text: "a", url: "https://x.example/a (b)", from: 0, to: 30)
    }

    /// A selection that runs past the line's end still edits the link it starts in.
    func testASelectionRunningPastTheLineStillCountsAsInsideOnItsFirstLine() {
        expect(draft("[a](u)\nnext", 1, 9), text: "a", url: "u", from: 0, to: 6)
    }

    /// Offsets are UTF-16 units: the emoji before the link is two of them.
    func testRangesAreUtf16AfterAnAstralCharacter() {
        expect(draft("😀 [a](u)", 4), text: "a", url: "u", from: 3, to: 9)
    }

    // MARK: format

    func testFormatWritesTextAndUrl() {
        XCTAssertEqual(
            MarkdownLinkEditing.format(text: "Photos", url: "https://p.example"), "[Photos](https://p.example)")
    }

    func testFormatUsesTheUrlWhenTheTextIsEmpty() {
        XCTAssertEqual(
            MarkdownLinkEditing.format(text: " ", url: "https://p.example"),
            "[https://p.example](https://p.example)")
    }

    func testFormatWrapsAUrlWithASpaceOrParenthesisInAngleBrackets() {
        XCTAssertEqual(
            MarkdownLinkEditing.format(text: "a", url: "https://x.example/a (b)"), "[a](<https://x.example/a (b)>)")
    }

    func testFormatEscapesBracketsInTheText() {
        XCTAssertEqual(MarkdownLinkEditing.format(text: "a [b]", url: "u"), "[a \\[b\\]](u)")
    }

    // MARK: edit

    func testEditReplacesTheDraftRangeAndLeavesTheCaretAfterTheLink() throws {
        let text = "x [Photos](https://p.example/s) y"
        let draft = draft(text, 5)
        let edit = try XCTUnwrap(MarkdownLinkEditing.edit(replacing: draft, text: "Pics", url: " https://q.example "))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        XCTAssertEqual(result, "x [Pics](https://q.example) y")
        XCTAssertEqual(edit.selection, NSRange(location: 2 + "[Pics](https://q.example)".utf16.count, length: 0))
    }

    func testOnlyANonBlankAddressCountsAsOne() {
        XCTAssertFalse(MarkdownLinkEditing.hasAddress(nil))
        XCTAssertFalse(MarkdownLinkEditing.hasAddress(" \n"))
        XCTAssertTrue(MarkdownLinkEditing.hasAddress(" a "))
    }

    func testEditWithoutAnAddressMakesNoEdit() {
        XCTAssertNil(MarkdownLinkEditing.edit(replacing: draft("abc", 1), text: "a", url: "  "))
    }

    // MARK: unlink

    func testUnlinkReplacesTheWholeLinkWithItsLabelAndLeavesTheCaretAfterIt() throws {
        let text = "x [Photos](https://p.example/s) y"
        let edit = try XCTUnwrap(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 5), in: text))
        XCTAssertEqual((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "x Photos y")
        XCTAssertEqual(edit.selection, NSRange(location: 2 + "Photos".utf16.count, length: 0))
    }

    /// Only `\\[` can appear: the link pattern ends a label at the first `]`, so a link whose label
    /// holds an escaped `\\]` is never recognised as one (the web's pattern is the same).
    func testUnlinkUndoesTheEscapeFormatWrites() throws {
        let text = MarkdownLinkEditing.format(text: "a [b", url: "u")
        XCTAssertEqual(text, "[a \\[b](u)")
        let edit = try XCTUnwrap(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 2), in: text))
        XCTAssertEqual(edit.replacement, "a [b")
    }

    func testUnlinkFallsBackToTheUrlForAnEmptyLabel() throws {
        let text = "[](https://p.example)"
        let edit = try XCTUnwrap(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 1), in: text))
        XCTAssertEqual(edit.replacement, "https://p.example")
    }

    func testUnlinkIsOfferedOnlyOnAnExistingMarkdownLink() {
        let text = "see https://p.example and [a](b)"
        XCTAssertNil(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 8), in: text), "bare URL")
        XCTAssertNil(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 0), in: text), "new link")
        XCTAssertNil(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 0, 3), in: text), "selected text")
        XCTAssertNotNil(MarkdownLinkEditing.unlinkEdit(replacing: draft(text, 28), in: text))
    }
}
