import XCTest

@testable import PAIKit

final class TranscriptAnchorTests: XCTestCase {

    func testNoAnchorFallsBackToBottom() {
        XCTAssertEqual(TranscriptRestore.target(for: nil, loadedMessageIds: [1, 2, 3]), .bottom)
    }

    /// An anchor recorded at the live edge must not be "restored" to literally — the reader was
    /// at the bottom, so the bottom is exactly where a session switch should land regardless of
    /// which row happened to be on top at that instant.
    func testAnchorAtLiveEdgeFallsBackToBottomEvenIfTheRowIsStillLoaded() {
        let anchor = TranscriptAnchor(messageId: 2, offset: 0, atLiveEdge: true)
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3]), .bottom)
    }

    /// The row the anchor names may have been dropped by LRU eviction since it was recorded —
    /// restoring to a row that no longer exists is not an option, and guessing a nearby one is
    /// explicitly rejected in favor of the predictable fallback.
    func testAnchorRowNoLongerLoadedFallsBackToBottom() {
        let anchor = TranscriptAnchor(messageId: 99, offset: 40, atLiveEdge: false)
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3]), .bottom)
    }

    func testAnchorAwayFromTheEdgeAndStillLoadedRestoresToItsRow() {
        let anchor = TranscriptAnchor(messageId: 2, offset: 40, atLiveEdge: false)
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3]), .message(id: 2))
    }
}
