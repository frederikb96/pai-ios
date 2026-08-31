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

    /// The caret has to be a zero-length point right after the marker, not a selection spanning
    /// the whole rewritten line — a selected line is what the very next keystroke overwrites,
    /// content and all. A blank line is the common case: tap Bullet, then type the item.
    func testBulletOnABlankLineLeavesACaretAfterTheMarkerNotASelection() {
        let (text, selection) = applied(.bulletList, to: "", NSRange(location: 0, length: 0))!
        XCTAssertEqual(text, "- ")
        XCTAssertEqual(selection, NSRange(location: 2, length: 0))
    }

    func testCheckboxOnABlankLineLeavesACaretAfterTheMarker() {
        let (text, selection) = applied(.checkbox, to: "", NSRange(location: 0, length: 0))!
        XCTAssertEqual(text, "- [ ] ")
        XCTAssertEqual(selection, NSRange(location: 6, length: 0))
    }

    func testQuoteOnABlankLineLeavesACaretAfterTheMarker() {
        let (text, selection) = applied(.quote, to: "", NSRange(location: 0, length: 0))!
        XCTAssertEqual(text, "> ")
        XCTAssertEqual(selection, NSRange(location: 2, length: 0))
    }

    /// The caret was mid-word ("th" | "ing"), not at an edge — it has to keep the same content
    /// next to it afterwards, shifted only by however much the marker itself grew.
    func testACaretMidWordKeepsItsPositionRelativeToTheContent() {
        let (text, selection) = applied(.bulletList, to: "thing", NSRange(location: 2, length: 0))!
        XCTAssertEqual(text, "- thing")
        XCTAssertEqual(selection, NSRange(location: 4, length: 0))
    }

    /// Replacing a shorter existing marker with a longer one (bullet -> checkbox) still has to
    /// leave a caret, not a selection spanning the new marker plus the original text.
    func testCheckboxReplacingABulletLeavesACaretNotASelection() {
        let (text, selection) = applied(.checkbox, to: "- thing", NSRange(location: 3, length: 0))!
        XCTAssertEqual(text, "- [ ] thing")
        XCTAssertEqual(selection, NSRange(location: 7, length: 0))
    }

    /// A real multi-line selection still collapses to a caret rather than a selection spanning
    /// the freshly-inserted markers — landing where the first line's own content now starts.
    func testAMultiLineSelectionCollapsesToACaretPastTheFirstMarker() {
        let (text, selection) = applied(.bulletList, to: "one\ntwo", NSRange(location: 0, length: 7))!
        XCTAssertEqual(text, "- one\n- two")
        XCTAssertEqual(selection, NSRange(location: 2, length: 0))
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

/// Indent and outdent, matching the web editor's own (`noteEditing.ts`'s `indentLines` /
/// `outdentLines`): a tab per line, on and off.
final class MarkdownIndentTests: XCTestCase {

    private func applied(_ command: MarkdownCommand, to text: String, _ selection: NSRange) -> (String, NSRange)? {
        guard let edit = MarkdownEditing.edit(command, in: text, selection: selection) else { return nil }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        return (mutable as String, edit.selection)
    }

    func testIndentAddsATabToEveryLineTheSelectionTouches() {
        let (text, _) = applied(.indent, to: "one\ntwo\nthree", NSRange(location: 1, length: 6))!
        XCTAssertEqual(text, "\tone\n\ttwo\nthree")
    }

    /// A caret with nothing selected still indents the line it is on.
    func testIndentWithAnEmptyCaretIndentsItsOwnLine() {
        let (text, selection) = applied(.indent, to: "item", NSRange(location: 2, length: 0))!
        XCTAssertEqual(text, "\titem")
        XCTAssertEqual(selection, NSRange(location: 3, length: 0), "the caret follows the content, shifted by the tab")
    }

    func testOutdentRemovesALeadingTab() {
        XCTAssertEqual(applied(.outdent, to: "\titem", NSRange(location: 3, length: 0))!.0, "item")
    }

    /// No tab: up to four leading spaces come off instead, matching the web's own fallback.
    func testOutdentFallsBackToUpToFourLeadingSpaces() {
        XCTAssertEqual(applied(.outdent, to: "      deep", NSRange(location: 8, length: 0))!.0, "  deep")
    }

    /// A line with neither is left alone rather than eating into its own content.
    func testOutdentOnAnUnindentedLineDoesNothing() {
        XCTAssertEqual(applied(.outdent, to: "flush", NSRange(location: 0, length: 0))!.0, "flush")
    }

    /// Indenting and outdenting are exact inverses for the common case, which is what makes
    /// pressing the button twice in a row feel predictable.
    func testIndentThenOutdentRoundTrips() {
        let (indented, _) = applied(.indent, to: "line", NSRange(location: 0, length: 0))!
        XCTAssertEqual(applied(.outdent, to: indented, NSRange(location: 0, length: 0))!.0, "line")
    }

    /// A real multi-line selection stays selected across the whole reindented block — matching
    /// the web editor — so repeated taps keep indenting (or outdenting) the same lines.
    func testIndentKeepsAMultiLineSelectionSelected() {
        let (text, selection) = applied(.indent, to: "one\ntwo", NSRange(location: 0, length: 7))!
        XCTAssertEqual(text, "\tone\n\ttwo")
        XCTAssertEqual(selection, NSRange(location: 0, length: 9))
    }
}

/// The heading button against levels it does not itself produce.
final class MarkdownHeadingCycleTests: XCTestCase {

    private func heading(_ text: String) -> String {
        guard let edit = MarkdownEditing.edit(.heading, in: text, selection: NSRange(location: 0, length: 0))
        else { return text }
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        return mutable as String
    }

    /// A `####` typed by hand or pasted from elsewhere is a heading. Recognising only the three
    /// levels the button produces would prepend to it, giving `# #### Title`.
    func testADeeperHeadingIsStrippedRatherThanPrependedTo() {
        XCTAssertEqual(heading("#### Deep"), "Deep")
        XCTAssertEqual(heading("###### Deepest"), "Deepest")
    }

    /// A hash with no space after it is not a heading — a `#tag` at the start of a line must not
    /// lose its hash to the heading button.
    func testAHashWithNoSpaceIsNotAHeading() {
        XCTAssertEqual(heading("#tag and more"), "# #tag and more")
    }
}
