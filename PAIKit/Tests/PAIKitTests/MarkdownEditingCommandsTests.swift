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

    /// A real multi-line selection stays a selection over the same text, so pressing the button
    /// again acts on the same lines; its start moves past the marker inserted at its own position.
    func testAMultiLineSelectionStaysSelectedAcrossTheNewMarkers() {
        let (text, selection) = applied(.bulletList, to: "one\ntwo", NSRange(location: 0, length: 7))!
        XCTAssertEqual(text, "- one\n- two")
        XCTAssertEqual(selection, NSRange(location: 2, length: 9))
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

/// The bullet and checkbox buttons: the same cases as the web editor's `noteEditing.test.ts`
/// (`toggleBulletLines`, `toggleCheckboxLine`), because both clients must cycle a line identically.
final class MarkdownListButtonTests: XCTestCase {

    /// Presses a button the way a tap does: select, run, read the text back.
    private func press(
        _ command: MarkdownCommand, _ text: String, _ from: Int = 0, _ to: Int? = nil
    ) -> (text: String, selection: NSRange) {
        let selection = NSRange(location: from, length: (to ?? from) - from)
        let edit = MarkdownEditing.edit(command, in: text, selection: selection)!
        let mutable = NSMutableString(string: text)
        mutable.replaceCharacters(in: edit.range, with: edit.replacement)
        return (mutable as String, edit.selection)
    }

    private func bullet(_ text: String, _ from: Int = 0, _ to: Int? = nil) -> String {
        press(.bulletList, text, from, to).text
    }

    private func checkbox(_ text: String, _ from: Int = 0, _ to: Int? = nil) -> String {
        press(.checkbox, text, from, to).text
    }

    // MARK: Bullet

    func testBulletAddsADashToAPlainLine() {
        XCTAssertEqual(bullet("plain line", 5), "- plain line")
    }

    func testBulletRemovesAPlainBulletWhicheverMarkerKeepingItsIndentation() {
        XCTAssertEqual(bullet("- already a bullet", 5), "already a bullet")
        XCTAssertEqual(bullet("* starred", 3), "starred")
        XCTAssertEqual(bullet("  - nested", 5), "  nested")
    }

    func testBulletGoesAfterTheIndentationOfAnIndentedPlainLine() {
        XCTAssertEqual(bullet("    deep", 6), "    - deep")
        XCTAssertEqual(bullet("\tdeep", 3), "\t- deep")
    }

    /// Task -> bullet -> (again) plain, and the bullet keeps the task's own marker character.
    func testBulletTurnsATaskIntoABulletThenTheNextPressRemovesIt() {
        let first = bullet("* [x] done", 8)
        XCTAssertEqual(first, "* done")
        XCTAssertEqual(bullet(first, 4), "done")
        XCTAssertEqual(bullet("- [ ] open", 8), "- open")
    }

    func testBulletSwapsTheNumberOfANumberedLine() {
        XCTAssertEqual(bullet("1. first", 4), "- first")
        XCTAssertEqual(bullet("  2) second", 6), "  - second")
    }

    func testBulletMakesAMixedSelectionUniform() {
        XCTAssertEqual(bullet("- a\nb\n- [ ] c\n3. d", 0, 18), "- a\n- b\n- c\n- d")
    }

    func testBulletRoundTripsAMultiLineSelectionAndLeavesBlankLinesAlone() {
        let value = "a\n\nb"
        let on = press(.bulletList, value, 0, value.utf16.count)
        XCTAssertEqual(on.text, "- a\n\n- b")
        XCTAssertEqual(bullet(on.text, 0, on.text.utf16.count), value)
    }

    func testBulletOnAnEmptyLineLeavesTheCaretAfterTheMarker() {
        let result = press(.bulletList, "", 0)
        XCTAssertEqual(result.text, "- ")
        XCTAssertEqual(result.selection, NSRange(location: 2, length: 0))
    }

    func testBulletKeepsTheCaretOnTheSameCharacterWhenItRemovesAMarkerBeforeIt() {
        let result = press(.bulletList, "- [ ] open", 8)
        XCTAssertEqual(result.text, "- open")
        XCTAssertEqual(result.selection, NSRange(location: 4, length: 0))
    }

    /// A box with no space after it is part of the text, not a task, so the bullet stays plain.
    func testBulletTreatsABoxGluedToTextAsOrdinaryBulletText() {
        XCTAssertEqual(bullet("- [ ]x", 3), "[ ]x")
    }

    // MARK: Checkbox

    func testCheckboxStartsAnEmptyTaskOnAPlainEmptyAndIndentedLine() {
        XCTAssertEqual(checkbox("buy milk", 3), "- [ ] buy milk")
        XCTAssertEqual(checkbox("", 0), "- [ ] ")
        XCTAssertEqual(checkbox("  buy milk", 4), "  - [ ] buy milk")
    }

    func testCheckboxAddsAnEmptyBoxToABulletWithoutRewritingTheMarker() {
        XCTAssertEqual(checkbox("- buy milk", 3), "- [ ] buy milk")
        XCTAssertEqual(checkbox("* buy milk", 3), "* [ ] buy milk")
    }

    func testCheckboxReplacesTheNumberOfANumberedLine() {
        XCTAssertEqual(checkbox("3. buy milk", 5), "- [ ] buy milk")
    }

    func testCheckboxCyclesEmptyCheckedEmptyCheckedAndNeverRemovesTheTask() {
        var value = "buy milk"
        var seen: [String] = []
        for _ in 0..<5 {
            value = checkbox(value, 3)
            seen.append(value)
        }
        XCTAssertEqual(
            seen,
            ["- [ ] buy milk", "- [x] buy milk", "- [ ] buy milk", "- [x] buy milk", "- [ ] buy milk"])
    }

    func testCheckboxTreatsACapitalXAsChecked() {
        XCTAssertEqual(checkbox("- [X] done", 3), "- [ ] done")
    }

    func testCheckboxHandlesATaskWithNoTextAfterTheBox() {
        XCTAssertEqual(checkbox("- [ ]", 2), "- [x]")
    }

    /// The first non-blank line decides the step; every line gets the same one.
    func testCheckboxAppliesTheFirstLinesStepToEverySelectedLine() {
        let value = "- [ ] one\nplain two\n- [x] three"
        XCTAssertEqual(
            checkbox(value, 0, value.utf16.count), "- [x] one\n- [x] plain two\n- [x] three")
        let mixed = "plain\n- [x] done"
        XCTAssertEqual(checkbox(mixed, 0, mixed.utf16.count), "- [ ] plain\n- [ ] done")
    }

    func testCheckboxKeepsTheCaretOnTheSameCharacterOfTheText() {
        XCTAssertEqual(press(.checkbox, "buy milk", 3).selection, NSRange(location: 9, length: 0))
        XCTAssertEqual(press(.checkbox, "- [ ] buy", 8).selection, NSRange(location: 8, length: 0))
    }

    /// The button pair Freddy asked for: task -> bullet -> plain.
    func testCheckboxThenBulletThenBulletEndsUpPlain() {
        let task = checkbox("note", 2)
        let asBullet = bullet(task, 4)
        XCTAssertEqual(asBullet, "- note")
        XCTAssertEqual(bullet(asBullet, 3), "note")
    }

    /// UTF-16 offsets: an emoji before the caret must not shift the marker into the word.
    func testCheckboxOffsetsAreUtf16() {
        let result = press(.checkbox, "🎉 party", 3)
        XCTAssertEqual(result.text, "- [ ] 🎉 party")
        XCTAssertEqual(result.selection, NSRange(location: 9, length: 0))
    }
}
