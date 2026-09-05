import XCTest

@testable import PAIKit

/// `EditDiff.lines` is what fixes the actual reported bug: every continuation line of a
/// multi-line old/new string used to render in plain text because the `-`/`+` prefix was glued
/// onto the whole block once rather than onto every line. These assert on the real bug shape —
/// a multi-line change where only the first line of each side used to carry a prefix.
final class EditDiffTests: XCTestCase {

    // MARK: - lines

    /// The exact shape from the report: a multi-line old and new string sharing no lines. Every
    /// line of both sides must carry its own prefix, not just the first one of each block.
    func testEveryLineOfAMultiLineChangeCarriesItsOwnMarker() {
        let lines = EditDiff.lines(old: "one\ntwo", new: "three\nfour")

        XCTAssertEqual(lines, [.removed("one"), .removed("two"), .added("three"), .added("four")])
    }

    /// A line shared by both sides must appear once, not once under `-` and once under `+` the
    /// way the naive whole-block gluing produced.
    func testAnUnchangedLineAppearsOnceAsContextNotOnBothSides() {
        let lines = EditDiff.lines(old: "keep\nold line", new: "keep\nnew line")

        XCTAssertEqual(lines, [.context("keep"), .removed("old line"), .added("new line")])
    }

    func testAPureAdditionHasNoRemovedLines() {
        let lines = EditDiff.lines(old: "same", new: "same\nadded")

        XCTAssertEqual(lines, [.context("same"), .added("added")])
    }

    func testAPureDeletionHasNoAddedLines() {
        let lines = EditDiff.lines(old: "same\nremoved", new: "same")

        XCTAssertEqual(lines, [.context("same"), .removed("removed")])
    }

    func testIdenticalOldAndNewProduceOnlyContext() {
        let lines = EditDiff.lines(old: "a\nb\nc", new: "a\nb\nc")

        XCTAssertEqual(lines, [.context("a"), .context("b"), .context("c")])
    }

    func testEmptyOldStringIsAWholeFileAddition() {
        let lines = EditDiff.lines(old: "", new: "one\ntwo")

        XCTAssertEqual(lines, [.added("one"), .added("two")])
    }

    // MARK: - changedLinePairs

    func testEqualLengthRemovedAndAddedRunsPairIndexForIndex() {
        let lines: [EditDiff.Line] = [.context("ctx"), .removed("a1"), .removed("a2"), .added("b1"), .added("b2")]

        let pairs = EditDiff.changedLinePairs(in: lines)

        XCTAssertEqual(pairs.map(\.removedIndex), [1, 2])
        XCTAssertEqual(pairs.map(\.addedIndex), [3, 4])
    }

    /// A run of different lengths is a restructuring, not a small in-place edit — left unpaired
    /// rather than guessing which removed line corresponds to which added one.
    func testUnequalLengthRunsAreNotPaired() {
        let lines: [EditDiff.Line] = [.removed("a"), .added("b"), .added("c")]

        XCTAssertTrue(EditDiff.changedLinePairs(in: lines).isEmpty)
    }

    func testAPureAdditionOrDeletionHasNoPairs() {
        XCTAssertTrue(EditDiff.changedLinePairs(in: [.context("x"), .added("y")]).isEmpty)
        XCTAssertTrue(EditDiff.changedLinePairs(in: [.context("x"), .removed("y")]).isEmpty)
    }

    // MARK: - wordDiff

    func testWordDiffMarksOnlyTheChangedWord() {
        let result = EditDiff.wordDiff(removed: "let x = 1", added: "let x = 2")

        XCTAssertEqual(result.removed.map(\.text), ["let", " ", "x", " ", "=", " ", "1"])
        XCTAssertEqual(result.removed.map(\.changed), [false, false, false, false, false, false, true])
        XCTAssertEqual(result.added.map(\.text), ["let", " ", "x", " ", "=", " ", "2"])
        XCTAssertEqual(result.added.map(\.changed), [false, false, false, false, false, false, true])
    }

    /// A pure whitespace change (a re-indent) must still surface as a change rather than
    /// vanishing because whitespace was folded into its neighbouring word.
    func testAWhitespaceOnlyChangeIsDetected() {
        let result = EditDiff.wordDiff(removed: "  indented", added: "    indented")

        XCTAssertTrue(result.removed.first?.changed ?? false)
        XCTAssertTrue(result.added.first?.changed ?? false)
    }

    func testTokenizeSplitsOnWhitespaceBoundariesAndReconstructsExactly() {
        let line = "  hello   world"
        let tokens = EditDiff.tokenize(line)

        XCTAssertEqual(tokens.joined(), line, "tokenizing must be exactly reversible by concatenation")
        XCTAssertEqual(tokens, ["  ", "hello", "   ", "world"])
    }
}
