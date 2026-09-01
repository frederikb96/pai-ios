import XCTest

@testable import PAIKit

/// Return inside a list. Every case here is one a phone keyboard makes tedious to repair by hand —
/// re-typing a marker is annoying, and re-typing the indentation of a nested item is worse, because
/// getting it wrong silently flattens the list when the note is rendered.
final class MarkdownListContinuationTests: XCTestCase {

    private func onReturn(_ text: String, at caret: Int? = nil) -> MarkdownListContinuation.Continuation? {
        MarkdownListContinuation.onReturn(text: text, caretUtf16: caret ?? text.utf16.count)
    }

    // MARK: Carrying the marker down

    func testABulletCarriesItsMarkerToTheNextLine() {
        XCTAssertEqual(onReturn("- one"), .init(deleteBefore: 0, insert: "\n- "))
    }

    func testTheOtherBulletCharactersAreCarriedAsThemselves() {
        XCTAssertEqual(onReturn("* one")?.insert, "\n* ")
        XCTAssertEqual(onReturn("+ one")?.insert, "\n+ ")
    }

    /// The one that matters most on a phone: indentation is what makes a list nested, and it is the
    /// part nobody can retype accurately with a thumb.
    func testANestedBulletKeepsItsIndentation() {
        XCTAssertEqual(onReturn("- top\n    - nested")?.insert, "\n    - ")
    }

    func testTabIndentationSurvivesAsTabs() {
        XCTAssertEqual(onReturn("-\tone")?.insert, "\n-\t")
    }

    /// A checked box copied down would tick off work nobody has done.
    func testATaskItemContinuesUnchecked() {
        XCTAssertEqual(onReturn("- [x] done")?.insert, "\n- [ ] ")
        XCTAssertEqual(onReturn("- [ ] todo")?.insert, "\n- [ ] ")
    }

    func testAnOrderedItemCountsUp() {
        XCTAssertEqual(onReturn("1. one")?.insert, "\n2. ")
        XCTAssertEqual(onReturn("  9) nine")?.insert, "\n  10) ")
    }

    // MARK: Leaving a list

    /// Pressing Return on an empty item is how someone stops listing. Carrying the marker down
    /// there produces an endless ladder of empty bullets that then have to be deleted one by one.
    func testReturnOnAnEmptyItemTakesTheMarkerAway() {
        XCTAssertEqual(onReturn("- one\n- "), .init(deleteBefore: 2, insert: ""))
    }

    func testLeavingANestedListRemovesTheIndentationToo() {
        XCTAssertEqual(onReturn("- top\n    - "), .init(deleteBefore: 6, insert: ""))
    }

    func testAnEmptyTaskItemIsAlsoLeft() {
        XCTAssertEqual(onReturn("- [ ] "), .init(deleteBefore: 6, insert: ""))
    }

    // MARK: Where it must keep out of the way

    func testOrdinaryProseIsLeftToTheTextView() {
        XCTAssertNil(onReturn("just a paragraph"))
    }

    /// `---` is a thematic break, and a line of dashes with no space after the first one is not a
    /// list item. Reading it as one would insert a bullet under every horizontal rule.
    func testAThematicBreakIsNotAList() {
        XCTAssertNil(onReturn("---"))
        XCTAssertNil(onReturn("***"))
    }

    func testADigitWithNoDelimiterIsNotAList() {
        XCTAssertNil(onReturn("2026 was a year"))
    }

    /// The caret inside the marker means the reader is splitting the bullet itself. Continuing
    /// there would insert a second marker in the middle of the first.
    func testACaretInsideTheMarkerIsAnOrdinaryLineBreak() {
        XCTAssertNil(onReturn("- one", at: 1))
    }

    /// The caret arrives as an `NSRange` location, which counts UTF-16. Measured in Characters
    /// instead, every offset past the first emoji in a note is short by one — and the symptom is
    /// Return quietly doing nothing on exactly the lists that contain one.
    func testACaretIsMeasuredInUtf16() {
        let text = "- 🎉 done\n- "
        XCTAssertEqual(onReturn(text), .init(deleteBefore: 2, insert: ""))
    }

    // MARK: Marker width, on its own

    /// `"- "` is two characters — a hanging indent hangs a wrapped continuation from exactly
    /// this width, the same prefix `onReturn` copies down to the next bullet.
    func testABulletsMarkerWidthIsTheDashAndTheSpace() {
        XCTAssertEqual(MarkdownListContinuation.markerPrefixLength(ofLine: "- one"), 2)
    }

    func testAnOrderedMarkersWidthIncludesTheDigitsAndTheDelimiter() {
        XCTAssertEqual(MarkdownListContinuation.markerPrefixLength(ofLine: "12. one"), 4)
    }

    func testATaskMarkersWidthIncludesTheCheckbox() {
        XCTAssertEqual(MarkdownListContinuation.markerPrefixLength(ofLine: "- [ ] todo"), 6)
    }

    func testANestedBulletsWidthIncludesItsIndentation() {
        XCTAssertEqual(MarkdownListContinuation.markerPrefixLength(ofLine: "    - nested"), 6)
    }

    func testOrdinaryProseHasNoMarkerWidth() {
        XCTAssertNil(MarkdownListContinuation.markerPrefixLength(ofLine: "just a paragraph"))
    }
}
