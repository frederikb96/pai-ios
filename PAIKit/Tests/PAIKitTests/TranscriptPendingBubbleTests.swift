import XCTest

@testable import PAIKit

/// The pending bubble is a *synthesised* row: it never comes off the wire, so nothing about its
/// shape is exercised by decoding a fixture, and the code that draws it does not know it is
/// special. That makes the two things below the whole of its contract, and both are the kind that
/// break silently — the bubble simply stops appearing, and a queued message looks lost.
final class TranscriptPendingBubbleTests: XCTestCase {

    func testPendingBubbleRendersAsAUserBubbleCarryingItsText() {
        let card = TranscriptRowPlan.cards(
            for: .pendingBubble(sessionId: "s", index: 0, text: "queued message"), isExpanded: { _ in true }
        ).first

        guard case .userBubble(let text, let attachmentPaths) = card?.kind else {
            return XCTFail("a pending bubble must route to a user bubble, got \(String(describing: card?.kind))")
        }
        XCTAssertEqual(text, "queued message")
        XCTAssertEqual(attachmentPaths, [])
    }

    /// `displayMessages` drops content-free rows, and the transcript pipes every row through it.
    /// A pending bubble that did not survive that filter would be measured, planned and then
    /// quietly discarded before it could ever be drawn.
    @MainActor
    func testPendingBubbleSurvivesTheDisplayFilter() async {
        let bubble = Message.pendingBubble(sessionId: "s", index: 0, text: "queued message")
        XCTAssertEqual(TranscriptStore.displayMessages([bubble]).map(\.id), [bubble.id])
    }

    /// Ids have to stay clear of the server's, which start at 1 and climb: the transcript's
    /// scroll anchoring keys on row id, so a bubble colliding with a real row would anchor the
    /// reader to the wrong one — a failure that shows up as the list jumping, far from here.
    func testPendingBubbleIdsAreNegativeAndDistinct() {
        let ids = (0..<3).map { Message.pendingBubble(sessionId: "s", index: $0, text: "t").id }
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertTrue(ids.allSatisfy { $0 < 0 }, "got \(ids)")
    }
}
