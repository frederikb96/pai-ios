import XCTest

@testable import PAIKit

/// What the formatting bar and Return handling both key off: whether the caret sits inside a
/// fenced code block. Getting this wrong either lets a formatting button splice markup into code,
/// or hides the formatting bar somewhere it should be available.
final class MarkdownFenceStateTests: XCTestCase {

    func testACaretBeforeAnyFenceIsNotInsideOne() {
        XCTAssertFalse(MarkdownFenceState.isInsideFence(text: "hello\n", caretUtf16: 3))
    }

    func testACaretOnTheLineInsideAFenceIsInsideIt() {
        let text = "before\n\n```\ncode\n```\n\nafter\n"
        let caret = text.range(of: "code")!.upperBound.utf16Offset(in: text)
        XCTAssertTrue(MarkdownFenceState.isInsideFence(text: text, caretUtf16: caret))
    }

    func testACaretAfterAClosedFenceIsNotInsideIt() {
        let text = "```\ncode\n```\nafter\n"
        let caret = text.range(of: "after")!.upperBound.utf16Offset(in: text)
        XCTAssertFalse(MarkdownFenceState.isInsideFence(text: text, caretUtf16: caret))
    }

    /// The line that opens the fence is markup, not content — a caret sitting on the fence itself
    /// (before anything has been typed inside it) must not hide the formatting bar.
    func testACaretOnTheOpeningFenceLineIsNotYetInsideIt() {
        XCTAssertFalse(MarkdownFenceState.isInsideFence(text: "```swift\ncode\n```\n", caretUtf16: 2))
    }

    /// An unterminated fence runs to the end of the document — same rule the highlighter and the
    /// old segmenter both used, so a caret anywhere past an unclosed opener is still inside it.
    func testAnUnterminatedFenceStaysOpenToTheEnd() {
        XCTAssertTrue(MarkdownFenceState.isInsideFence(text: "```\ncode with no close", caretUtf16: 20))
    }

    func testACaretInsideANestedShorterFenceIsStillInsideTheOuterOne() {
        let text = "````\n```\ninner\n```\n````\n"
        let caret = text.range(of: "inner")!.lowerBound.utf16Offset(in: text) + 2
        XCTAssertTrue(MarkdownFenceState.isInsideFence(text: text, caretUtf16: caret))
    }

    /// A note written with Windows line endings must open and close a fence exactly like one
    /// written with bare `\n` — the line splitter this reads from ties a CRLF pair to the line it
    /// terminates, same as it would a bare `\n`.
    func testACaretInsideAFenceStaysInsideItAcrossCrlfLines() {
        let text = "before\r\n\r\n```\r\ncode\r\n```\r\n\r\nafter\r\n"
        let caret = text.range(of: "code")!.upperBound.utf16Offset(in: text)
        XCTAssertTrue(MarkdownFenceState.isInsideFence(text: text, caretUtf16: caret))
    }

    func testACaretAfterACrlfClosedFenceIsNotInsideIt() {
        let text = "```\r\ncode\r\n```\r\nafter\r\n"
        let caret = text.range(of: "after")!.upperBound.utf16Offset(in: text)
        XCTAssertFalse(MarkdownFenceState.isInsideFence(text: text, caretUtf16: caret))
    }
}
