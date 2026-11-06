import XCTest

@testable import PAIKit

final class TranscriptAnchorTests: XCTestCase {

    func testNoAnchorFallsBackToBottom() {
        XCTAssertEqual(TranscriptRestore.target(for: nil, loadedMessageIds: [1, 2, 3]), .bottom)
    }

    /// Left at the live edge and messages arrived since: back on the last one seen, not on the
    /// row that happened to be on top, and not at the bottom past what is unread.
    func testAnchorAtLiveEdgeWithNewerMessagesLandsOnTheLastOneSeen() {
        let anchor = TranscriptAnchor(
            messageId: 1, offset: -20, lastSeen: TranscriptRowPosition(messageId: 3, offset: 300))
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3, 4, 5]), .lastSeen(id: 3))
    }

    /// Nothing arrived: the reader is back at the edge, following.
    func testAnchorAtLiveEdgeWithNothingNewerFallsBackToBottom() {
        let anchor = TranscriptAnchor(
            messageId: 1, offset: -20, lastSeen: TranscriptRowPosition(messageId: 3, offset: 300))
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3]), .bottom)
    }

    func testAnchorAtLiveEdgeWhoseLastSeenRowIsNoLongerLoadedFallsBackToBottom() {
        let anchor = TranscriptAnchor(
            messageId: 1, offset: -20, lastSeen: TranscriptRowPosition(messageId: 3, offset: 300))
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [400, 401]), .bottom)
    }

    /// The row the anchor names may have been dropped by LRU eviction since it was recorded —
    /// restoring to a row that no longer exists is not an option, and guessing a nearby one is
    /// explicitly rejected in favor of the predictable fallback.
    func testAnchorRowNoLongerLoadedFallsBackToBottom() {
        let anchor = TranscriptAnchor(messageId: 99, offset: 40)
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3]), .bottom)
    }

    func testAnchorAwayFromTheEdgeAndStillLoadedRestoresToItsRow() {
        let anchor = TranscriptAnchor(messageId: 2, offset: 40)
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [1, 2, 3]), .message(id: 2))
    }

    // MARK: - readPositionPayload

    /// Caught up: the last message seen, not the top row — a return counts everything after the
    /// sent id as new.
    func testReadPositionPayloadAtLiveEdgeSendsTheLastMessageSeen() {
        let anchor = TranscriptAnchor(
            messageId: 7, offset: 12.9, lastSeen: TranscriptRowPosition(messageId: 9, offset: 410.4))
        let payload = TranscriptAnchor.readPositionPayload(for: anchor, hasNewer: false)
        XCTAssertEqual(payload.messageId, 9)
        XCTAssertEqual(payload.offsetPx, 410)
        XCTAssertTrue(payload.atBottom)
    }

    func testReadPositionPayloadAwayFromTheEdgeRoundsTheOffsetAndSendsAtBottomFalse() {
        let anchor = TranscriptAnchor(messageId: 7, offset: 12.6)
        let payload = TranscriptAnchor.readPositionPayload(for: anchor, hasNewer: false)
        XCTAssertEqual(payload.messageId, 7)
        XCTAssertEqual(payload.offsetPx, 13)
        XCTAssertFalse(payload.atBottom)
    }

    /// The bottom of a non-tail window is not the end of the conversation, whatever the
    /// geometry says — `hasNewer` overrides `lastSeen` even when the anchor itself was
    /// recorded as pinned to this window's own (non-tail) bottom.
    func testReadPositionPayloadWithNewerUnloadedNeverReportsAtBottomEvenIfLiveEdge() {
        let anchor = TranscriptAnchor(
            messageId: 7, offset: 12.6, lastSeen: TranscriptRowPosition(messageId: 9, offset: 410))
        let payload = TranscriptAnchor.readPositionPayload(for: anchor, hasNewer: true)
        XCTAssertEqual(payload.messageId, 7)
        XCTAssertEqual(payload.offsetPx, 13)
        XCTAssertFalse(payload.atBottom)
    }

    // MARK: - fromPersisted

    func testFromPersistedNilIsNothingToSeed() {
        XCTAssertNil(TranscriptAnchor.fromPersisted(nil))
    }

    /// `atBottom: true` with no message names nothing to come back to — the bottom, which a `nil`
    /// anchor already falls back to.
    func testFromPersistedAtBottomWithoutAMessageIsNothingToSeed() {
        let persisted = PersistedReadPosition(messageId: nil, offsetPx: nil, atBottom: true)
        XCTAssertNil(TranscriptAnchor.fromPersisted(persisted))
    }

    /// Recorded at the live edge on another device: a return here measures "arrived since"
    /// against the message that device last saw.
    func testFromPersistedAtBottomWithAMessageBuildsALastSeenAnchor() {
        let persisted = PersistedReadPosition(messageId: 42, offsetPx: 300, atBottom: true)
        let anchor = TranscriptAnchor.fromPersisted(persisted)
        XCTAssertEqual(anchor?.lastSeen, TranscriptRowPosition(messageId: 42, offset: 300))
        XCTAssertEqual(TranscriptRestore.target(for: anchor, loadedMessageIds: [41, 42, 43]), .lastSeen(id: 42))
    }

    func testFromPersistedWithAPositionBuildsAnAwayFromEdgeAnchor() {
        let persisted = PersistedReadPosition(messageId: 42, offsetPx: 88, atBottom: false)
        let anchor = TranscriptAnchor.fromPersisted(persisted)
        XCTAssertEqual(anchor, TranscriptAnchor(messageId: 42, offset: 88))
    }

    /// A malformed row missing one of the two fields should not fabricate a position.
    func testFromPersistedMissingAFieldWhileNotAtBottomIsNothingToSeed() {
        let persisted = PersistedReadPosition(messageId: 42, offsetPx: nil, atBottom: false)
        XCTAssertNil(TranscriptAnchor.fromPersisted(persisted))
    }
}
