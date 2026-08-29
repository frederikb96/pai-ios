import XCTest

@testable import PAIKit

final class TerminalPaneStateTests: XCTestCase {

    private let reset = TerminalFrameFolder.resetSequence

    /// The seam between fold and parse: applying a chunk must thread the *folded* text into the
    /// parser, not the raw incoming chunk — a regression here would parse only the newest
    /// fragment while a continuation chunk was silently accumulating unparsed text underneath it.
    func testApplyingAFullFrameParsesTheFoldedText() {
        let state = TerminalPaneState.initial.applying(TerminalFrameChunk(data: reset + "hello", live: true))

        XCTAssertEqual(state.rawText, "hello")
        XCTAssertEqual(state.screen.lines[0].runs.map(\.text).joined(), "hello")
    }

    /// A second full-screen frame must replace the screen outright rather than parsing on top of
    /// the first — the defining behavior this whole module exists to get right.
    func testSecondFullFrameReplacesRatherThanAccumulates() {
        let first = TerminalPaneState.initial.applying(TerminalFrameChunk(data: reset + "screen one", live: true))
        let second = first.applying(TerminalFrameChunk(data: reset + "screen two", live: true))

        XCTAssertEqual(second.rawText, "screen two")
    }

    /// `live` reflects only the most recent chunk's flag — a scrolled-back frame that happens to
    /// repeat earlier content must still flip the flag, or the "scrolled back" banner a view
    /// drives from this would never appear.
    func testLiveFlagTracksOnlyTheLatestChunk() {
        let live = TerminalPaneState.initial.applying(TerminalFrameChunk(data: reset + "content", live: true))
        let scrolledBack = live.applying(TerminalFrameChunk(data: reset + "older content", live: false))

        XCTAssertFalse(scrolledBack.live)
    }

    /// The pre-any-frame state is zero lines, distinguishable from a received-but-empty frame
    /// (one blank line) — a view must be able to tell "nothing yet" from "an empty pane" apart.
    func testInitialStateHasNoLinesAtAll() {
        XCTAssertEqual(TerminalPaneState.initial.screen.lines, [])
    }
}
