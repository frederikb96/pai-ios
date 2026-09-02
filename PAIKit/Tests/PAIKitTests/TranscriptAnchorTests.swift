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

    // MARK: - readPositionPayload

    /// Caught up: nothing to pin a message at, and a stale id is worse than none — the reader
    /// has moved on from it.
    func testReadPositionPayloadAtLiveEdgeSendsNoMessageAndAtBottomTrue() {
        let anchor = TranscriptAnchor(messageId: 7, offset: 12.9, atLiveEdge: true)
        let payload = TranscriptAnchor.readPositionPayload(for: anchor)
        XCTAssertNil(payload.messageId)
        XCTAssertNil(payload.offsetPx)
        XCTAssertTrue(payload.atBottom)
    }

    func testReadPositionPayloadAwayFromTheEdgeRoundsTheOffsetAndSendsAtBottomFalse() {
        let anchor = TranscriptAnchor(messageId: 7, offset: 12.6, atLiveEdge: false)
        let payload = TranscriptAnchor.readPositionPayload(for: anchor)
        XCTAssertEqual(payload.messageId, 7)
        XCTAssertEqual(payload.offsetPx, 13)
        XCTAssertFalse(payload.atBottom)
    }

    // MARK: - fromPersisted

    func testFromPersistedNilIsNothingToSeed() {
        XCTAssertNil(TranscriptAnchor.fromPersisted(nil))
    }

    /// `atBottom: true` needs no seed at all — the fallback for a `nil` anchor is already the
    /// bottom, so seeding one here would be redundant with what already happens.
    func testFromPersistedAtBottomIsNothingToSeed() {
        let persisted = PersistedReadPosition(messageId: nil, offsetPx: nil, atBottom: true)
        XCTAssertNil(TranscriptAnchor.fromPersisted(persisted))
    }

    func testFromPersistedWithAPositionBuildsAnAwayFromEdgeAnchor() {
        let persisted = PersistedReadPosition(messageId: 42, offsetPx: 88, atBottom: false)
        let anchor = TranscriptAnchor.fromPersisted(persisted)
        XCTAssertEqual(anchor, TranscriptAnchor(messageId: 42, offset: 88, atLiveEdge: false))
    }

    /// The two fields are `nil` together on the wire whenever `atBottom` is true, but a malformed
    /// row missing just one of them with `atBottom: false` should not fabricate a position either.
    func testFromPersistedMissingAFieldWhileNotAtBottomIsNothingToSeed() {
        let persisted = PersistedReadPosition(messageId: 42, offsetPx: nil, atBottom: false)
        XCTAssertNil(TranscriptAnchor.fromPersisted(persisted))
    }
}
