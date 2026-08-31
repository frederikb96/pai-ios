import Foundation
import XCTest

@testable import PAIKit

/// The formatting buttons above the keyboard. Each case here is a way a button can look like it
/// works and quietly produce markdown that renders as something else — or leave the caret
/// somewhere the next keystroke lands in the markup rather than in the text.
final class MarkdownEditingCommandsTests: XCTestCase {

    /// Applies an edit the way the text view does, so a test asserts on the resulting note rather
    /// than on the shape of the instruction.
    private func applied(_ command: MarkdownCommand, to text: String, _ selection: NSRange) -> (String, NSRange)? {
        guard let edit = MarkdownEditing.edit(command, in: text, selection: selection) else { return nil }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        return (mutable as String, edit.selection)
    }

    // MARK: Inline markers

    func testBoldWrapsTheSelection() {
        let (text, selection) = applied(.bold, to: "make this loud", NSRange(location: 5, length: 4))!
        XCTAssertEqual(text, "make **this** loud")
        XCTAssertEqual(
            selection, NSRange(location: 7, length: 4), "the selection must stay on the words, not the stars")
    }

    /// A formatting button that cannot undo itself is a one-way door: the only way back is to hunt
    /// for four asterisks with a thumb.
    func testBoldPressedTwiceUnwrapsAgain() {
        let (text, _) = applied(.bold, to: "make **this** loud", NSRange(location: 5, length: 8))!
        XCTAssertEqual(text, "make this loud")
    }

    /// The same, for the far commoner selection: the reader double-taps the word, which selects it
    /// *inside* the stars rather than around them.
    func testBoldUnwrapsWhenTheMarkersSitJustOutsideTheSelection() {
        let (text, selection) = applied(.bold, to: "make **this** loud", NSRange(location: 7, length: 4))!
        XCTAssertEqual(text, "make this loud")
        XCTAssertEqual(selection, NSRange(location: 5, length: 4))
    }

    /// With nothing selected the caret has to land between the markers. Left after them, the next
    /// word is typed outside the emphasis and the stars end up around nothing.
    func testBoldWithNoSelectionLeavesTheCaretBetweenTheMarkers() {
        let (text, selection) = applied(.bold, to: "say ", NSRange(location: 4, length: 0))!
        XCTAssertEqual(text, "say ****")
        XCTAssertEqual(selection, NSRange(location: 6, length: 0))
    }

    func testInlineCodeUsesASingleBacktick() {
        XCTAssertEqual(applied(.inlineCode, to: "run ls now", NSRange(location: 4, length: 2))!.0, "run `ls` now")
    }

    func testALinkPutsTheCaretWhereTheUrlGoes() {
        let (text, selection) = applied(.link, to: "see docs", NSRange(location: 4, length: 4))!
        XCTAssertEqual(text, "see [docs]()")
        XCTAssertEqual(selection, NSRange(location: 11, length: 0))
    }

    // MARK: Line prefixes

    func testBulletsAreAddedToEveryLineTheSelectionTouches() {
        let (text, _) = applied(.bulletList, to: "one\ntwo\nthree", NSRange(location: 1, length: 6))!
        XCTAssertEqual(text, "- one\n- two\nthree")
    }

    func testBulletsComeOffAgainWhenEveryLineHasOne() {
        let (text, _) = applied(.bulletList, to: "- one\n- two", NSRange(location: 0, length: 11))!
        XCTAssertEqual(text, "one\ntwo")
    }

    /// A half-formatted block finishes the job rather than undoing the half that was done.
    func testAMixedSelectionGainsThePrefixRatherThanLosingIt() {
        let (text, _) = applied(.bulletList, to: "- one\ntwo", NSRange(location: 0, length: 9))!
        XCTAssertEqual(text, "- one\n- two")
    }

    func testIndentationIsKeptWhenAPrefixIsAdded() {
        XCTAssertEqual(applied(.bulletList, to: "    deep", NSRange(location: 8, length: 0))!.0, "    - deep")
    }

    /// A checked box has to come off too — matching only `- [ ] ` would stack a second checkbox on
    /// top of a ticked one.
    func testACheckedBoxIsRemovedByTheCheckboxButton() {
        XCTAssertEqual(applied(.checkbox, to: "- [x] done", NSRange(location: 6, length: 0))!.0, "done")
    }

    func testACheckboxReplacesAPlainBulletRatherThanStackingOnIt() {
        XCTAssertEqual(applied(.checkbox, to: "- thing", NSRange(location: 3, length: 0))!.0, "- [ ] thing")
    }

    // MARK: Headings

    func testTheHeadingButtonWalksDownTheLevelsAndBackToNone() {
        var text = "title"
        for expected in ["# title", "## title", "### title", "title"] {
            text = applied(.heading, to: text, NSRange(location: 0, length: 0))!.0
            XCTAssertEqual(text, expected)
        }
    }

    func testHeadingOnlyTouchesTheLineTheCaretIsIn() {
        XCTAssertEqual(applied(.heading, to: "one\ntwo", NSRange(location: 5, length: 0))!.0, "one\n# two")
    }

    // MARK: Offsets

    /// Selections arrive as `NSRange`, which counts UTF-16. Anything measured in Characters is
    /// short by one for every emoji before it, and the markers then land inside a word.
    func testSelectionOffsetsAreUtf16() {
        let text = "🎉 party time"
        let (result, _) = applied(.bold, to: text, NSRange(location: 3, length: 5))!
        XCTAssertEqual(result, "🎉 **party** time")
    }

    func testASelectionPastTheEndIsRefusedRatherThanTrapping() {
        XCTAssertNil(MarkdownEditing.edit(.bold, in: "hi", selection: NSRange(location: 0, length: 99)))
    }
}
