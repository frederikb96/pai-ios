import XCTest

@testable import PAIKit

/// What the formatting bar and Return handling both key off: whether the caret sits inside a
/// fenced code block. Getting this wrong either lets a formatting button splice markup into code,
/// or hides the formatting bar somewhere it should be available.
final class MarkdownDocumentIndexTests: XCTestCase {

    private func isInsideFence(_ text: String, _ caret: Int) -> Bool {
        MarkdownDocumentIndex(text: text as NSString).isInsideFence(caret)
    }

    func testACaretBeforeAnyFenceIsNotInsideOne() {
        XCTAssertFalse(isInsideFence("hello\n", 3))
    }

    func testACaretOnTheLineInsideAFenceIsInsideIt() {
        let text = "before\n\n```\ncode\n```\n\nafter\n"
        let caret = text.range(of: "code")!.upperBound.utf16Offset(in: text)
        XCTAssertTrue(isInsideFence(text, caret))
    }

    func testACaretAfterAClosedFenceIsNotInsideIt() {
        let text = "```\ncode\n```\nafter\n"
        let caret = text.range(of: "after")!.upperBound.utf16Offset(in: text)
        XCTAssertFalse(isInsideFence(text, caret))
    }

    /// The line that opens the fence is markup, not content — a caret sitting on the fence itself
    /// (before anything has been typed inside it) must not hide the formatting bar.
    func testACaretOnTheOpeningFenceLineIsNotYetInsideIt() {
        XCTAssertFalse(isInsideFence("```swift\ncode\n```\n", 2))
    }

    /// An unterminated fence runs to the end of the document — same rule the highlighter and the
    /// old segmenter both used, so a caret anywhere past an unclosed opener is still inside it.
    func testAnUnterminatedFenceStaysOpenToTheEnd() {
        XCTAssertTrue(isInsideFence("```\ncode with no close", 20))
    }

    func testACaretInsideANestedShorterFenceIsStillInsideTheOuterOne() {
        let text = "````\n```\ninner\n```\n````\n"
        let caret = text.range(of: "inner")!.lowerBound.utf16Offset(in: text) + 2
        XCTAssertTrue(isInsideFence(text, caret))
    }

    /// A note written with Windows line endings must open and close a fence exactly like one
    /// written with bare `\n` — the line splitter this reads from ties a CRLF pair to the line it
    /// terminates, same as it would a bare `\n`.
    func testACaretInsideAFenceStaysInsideItAcrossCrlfLines() {
        let text = "before\r\n\r\n```\r\ncode\r\n```\r\n\r\nafter\r\n"
        let caret = text.range(of: "code")!.upperBound.utf16Offset(in: text)
        XCTAssertTrue(isInsideFence(text, caret))
    }

    func testACaretAfterACrlfClosedFenceIsNotInsideIt() {
        let text = "```\r\ncode\r\n```\r\nafter\r\n"
        let caret = text.range(of: "after")!.upperBound.utf16Offset(in: text)
        XCTAssertFalse(isInsideFence(text, caret))
    }

    func testACaretAfterTheLastTerminatorOfAnOpenFenceIsInsideIt() {
        XCTAssertTrue(isInsideFence("```\ncode\n", 9))
    }

    /// A fence marker inside frontmatter is metadata, and the highlighter has never read it as
    /// code; the caret below it must not lose the formatting bar.
    func testAFenceInsideFrontmatterOpensNothing() {
        let text = "---\nnote: ```\n---\nafter\n"
        XCTAssertFalse(isInsideFence(text, text.utf16.count - 2))
    }

    // MARK: Incremental edits

    /// Whatever an edit does, the index it updates in place must equal one built from scratch,
    /// or every later answer is wrong for the rest of the session with nothing to notice it.
    /// Edits land on the shapes where a local update could go wrong: terminators and CRLF pairs
    /// joining or splitting, fences and frontmatter delimiters appearing and vanishing, surrogate
    /// pairs, whole-range replacement.
    func testAnyEditLeavesTheSameIndexAsRebuildingFromTheText() {
        var generator = SeededGenerator(state: 0x5EED)
        let pieces = [
            "\n", "\r\n", "\r", "```\n", "```", "~~~~\n", "---\n", "---", "# h\n", "- item\n", "plain", " ",
            "a", "😀", "ü", "\u{2028}", "\n\n", "",
        ]
        var failures = 0
        var movedABlock = 0
        for _ in 0..<4000 {
            let seed = (0..<Int.random(in: 0...14, using: &generator)).map { _ in
                pieces.randomElement(using: &generator)!
            }
            let text = NSMutableString(string: seed.joined())
            var index = MarkdownDocumentIndex(text: text)
            for _ in 0..<4 {
                let location = Self.scalarBoundary(
                    Int.random(in: 0...text.length, using: &generator), in: text)
                let end = Self.scalarBoundary(
                    Int.random(in: location...min(location + 6, text.length), using: &generator), in: text)
                let removed = max(end - location, 0)
                let inserted = pieces.randomElement(using: &generator)!
                let before = text.copy() as! NSString
                text.replaceCharacters(in: NSRange(location: location, length: removed), with: inserted)
                let edited = NSRange(location: location, length: (inserted as NSString).length)
                let repaint = index.applyEdit(
                    editedRange: edited, delta: edited.length - removed, in: text)
                let fresh = MarkdownDocumentIndex(text: text)
                if index != fresh {
                    failures += 1
                    print(
                        "diverged: \(String(describing: before as String).debugDescription) replacing \(location)+\(removed) with \(inserted.debugDescription) got \(index.lineStarts) want \(fresh.lineStarts)"
                    )
                }
                if repaint.length > edited.length + 40 { movedABlock += 1 }
                XCTAssertLessThanOrEqual(repaint.upperBound, text.length)
                XCTAssertLessThanOrEqual(repaint.location, edited.location)
                XCTAssertGreaterThanOrEqual(repaint.upperBound, min(edited.upperBound, text.length))
            }
        }
        XCTAssertEqual(failures, 0)
        XCTAssertGreaterThan(movedABlock, 0, "no edit in this run moved a block boundary")
    }

    /// A text view never edits half a surrogate pair, and `NSMutableString` on Linux cannot hold one.
    private static func scalarBoundary(_ offset: Int, in text: NSString) -> Int {
        guard offset < text.length, (0xDC00...0xDFFF).contains(text.character(at: offset)) else { return offset }
        return offset - 1
    }

    func testTypingInsideAParagraphRepaintsNoLineBelowIt() {
        let text = NSMutableString(string: "one\ntwo\nthree\nfour\n")
        var index = MarkdownDocumentIndex(text: text)
        text.insert("x", at: 5)
        let repaint = index.applyEdit(editedRange: NSRange(location: 5, length: 1), delta: 1, in: text)
        XCTAssertEqual(repaint.upperBound, ("one\ntxwo\n" as NSString).length)
    }

    func testOpeningAFenceRepaintsTheLinesItSwallowsAndClosingItRepaintsThemBack() {
        let text = NSMutableString(string: "a\nb\nc\nd\n")
        var index = MarkdownDocumentIndex(text: text)
        text.insert("```\n", at: 2)
        var repaint = index.applyEdit(editedRange: NSRange(location: 2, length: 4), delta: 4, in: text)
        XCTAssertEqual(repaint.upperBound, text.length)
        XCTAssertTrue(index.isInsideFence(text.length))

        text.deleteCharacters(in: NSRange(location: 2, length: 4))
        repaint = index.applyEdit(editedRange: NSRange(location: 2, length: 0), delta: -4, in: text)
        XCTAssertEqual(repaint.upperBound, text.length)
        XCTAssertFalse(index.isInsideFence(text.length))
    }

    func testALineNumberBelongsOnlyToTheStartOfItsLine() {
        let index = MarkdownDocumentIndex(text: "one\r\ntwo\n" as NSString)
        XCTAssertEqual(index.lineNumber(startingAt: 0), 1)
        XCTAssertEqual(index.lineNumber(startingAt: 5), 2)
        XCTAssertEqual(index.lineNumber(startingAt: 9), 3)
        XCTAssertNil(index.lineNumber(startingAt: 2))
        XCTAssertNil(index.lineNumber(startingAt: 4))
    }
}

/// xorshift, so a failure replays from the seed on any platform.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
