import XCTest

@testable import PAIKit

final class TerminalFrameFolderTests: XCTestCase {

    /// The ordinary case: every real frame from the agent carries the reset marker, and it
    /// replaces whatever was buffered before — a fold that instead appended would duplicate the
    /// screen underneath itself on every single frame.
    func testChunkWithResetSequenceReplacesTheBuffer() {
        let chunk = TerminalFrameFolder.resetSequence + "fresh screen"
        let folded = TerminalFrameFolder.fold(previous: "stale screen from three frames ago", chunk: chunk)

        XCTAssertEqual(folded, "fresh screen")
    }

    /// The fallback path: a chunk with no reset marker is a continuation of whatever this buffer
    /// already held, not a screen of its own.
    func testChunkWithoutResetSequenceAppendsToTheBuffer() {
        let folded = TerminalFrameFolder.fold(previous: "partial ", chunk: "continuation")

        XCTAssertEqual(folded, "partial continuation")
    }

    /// If the marker were ever found by its *first* occurrence instead of its last, content that
    /// happens to contain it (a nested shell clearing its own screen) would be mistaken for the
    /// frame boundary and the real, later snapshot would be discarded instead of kept.
    func testLastOccurrenceOfResetSequenceWinsOverAnEarlierOne() {
        let reset = TerminalFrameFolder.resetSequence
        let chunk = reset + "an earlier, discarded screen" + reset + "the actual current screen"

        let folded = TerminalFrameFolder.fold(previous: "irrelevant", chunk: chunk)

        XCTAssertEqual(folded, "the actual current screen")
    }

    /// Content preceding the marker within the same chunk is discarded along with the buffer it
    /// replaces — the marker's presence at all means what follows it is the whole screen.
    func testResetSequenceNotAtTheChunkStartStillDiscardsEverythingBeforeIt() {
        let chunk = "garbage prefix" + TerminalFrameFolder.resetSequence + "the screen"

        let folded = TerminalFrameFolder.fold(previous: "old", chunk: chunk)

        XCTAssertEqual(folded, "the screen")
    }

    func testEmptyPreviousAndChunkFoldToEmpty() {
        XCTAssertEqual(TerminalFrameFolder.fold(previous: "", chunk: ""), "")
    }
}
