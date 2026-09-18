import Foundation
import XCTest

@testable import PAIKit

final class SearchTranscriptIndexTests: XCTestCase {

    private func message(
        id: Int,
        type: MessageType,
        subtype: String? = nil,
        content: String? = nil,
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil,
        toolResult: ToolResult? = nil
    ) -> Message {
        Message(
            id: id, sessionId: "s", type: type, subtype: subtype, outboxId: nil, timestamp: nil, content: content,
            thinking: thinking, toolCalls: toolCalls, toolResult: toolResult, hookSummary: nil, tokens: nil,
            origin: nil, originMeta: nil, createdAt: nil)
    }

    func testHitsIsEmptyForAnEmptyOrBlankQuery() {
        let msg = message(id: 1, type: .assistant, content: "needle in here")
        XCTAssertEqual(TranscriptSearchIndex.hits(in: [msg], query: "").hits, [])
        XCTAssertEqual(TranscriptSearchIndex.hits(in: [msg], query: "   ").hits, [])
    }

    func testHitsIsEmptyWhenNothingMatches() {
        let msg = message(id: 1, type: .assistant, content: "nothing to find")
        let (hits, truncated) = TranscriptSearchIndex.hits(in: [msg], query: "needle")
        XCTAssertEqual(hits, [])
        XCTAssertFalse(truncated)
    }

    /// The index forces every card open (see the type's own doc comment), so text the reader
    /// cannot currently see is still findable.
    ///
    /// The needle sits on line 25 of a 30-line result, well past the 8-line budget a result is
    /// shown at — a body short enough to be shown whole cannot tell a forced-open index from one
    /// built against what is on screen, and a fixture like that leaves this test passing even if
    /// the index stopped opening anything at all.
    func testHitsFindsTextPastWhatThePreviewShows() {
        let lines = (1...30).map { $0 == 25 ? "the needle is here" : "line \($0)" }
        let result = ToolResult(
            toolUseId: "1", toolName: "Bash", content: lines.joined(separator: "\n"), isError: false)
        let msg = message(id: 1, type: .toolResult, toolResult: result)

        // The preview genuinely stops short of it, or this proves nothing.
        let shown = TranscriptRowPlan.cards(for: msg, isRevealed: { _ in false })
        XCTAssertFalse(shown[0].blocks.contains { $0.plainText.contains("needle") })

        let (hits, _) = TranscriptSearchIndex.hits(in: [msg], query: "needle")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].messageId, 1)
        XCTAssertEqual(hits[0].cardIndex, 0)
        XCTAssertEqual(hits[0].blockIndex, 0)
    }

    /// A hit's `cardIndex` is what reveals its card, so it has to name the card the term is
    /// actually in — a turn with a thought before its tool call puts the call at index 1, and a
    /// caller revealing index 0 would open the thought and leave the hit hidden.
    func testHitsCardIndexNamesTheCardTheTermIsIn() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("echo needle")])]
        let msg = message(id: 1, type: .assistant, thinking: "considering the options", toolCalls: calls)

        let (hits, _) = TranscriptSearchIndex.hits(in: [msg], query: "needle")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].cardIndex, 1)
    }

    /// One assistant turn holding the term twice — twenty screens tall in the worst case — must
    /// produce two distinct, correctly-located hits, not one hit for the whole message.
    func testMultipleOccurrencesInOneMessageAreCountedSeparately() {
        let msg = message(id: 1, type: .assistant, content: "needle one, needle two")
        let (hits, _) = TranscriptSearchIndex.hits(in: [msg], query: "needle")
        XCTAssertEqual(hits.count, 2)
        XCTAssertNotEqual(hits[0].range, hits[1].range)
    }

    /// Hits must come out in the order the caller's messages were given — the render order a
    /// navigation index relies on — not sorted by anything the index invents on its own.
    func testHitsPreserveTheOrderOfTheMessagesArray() {
        let first = message(id: 5, type: .assistant, content: "needle")
        let second = message(id: 9, type: .assistant, content: "needle")
        let (hits, _) = TranscriptSearchIndex.hits(in: [first, second], query: "needle")
        XCTAssertEqual(hits.map(\.messageId), [5, 9])
    }

    func testHitsCapAtMaxHitsAndReportTruncation() {
        let content = String(repeating: "x ", count: TranscriptSearchIndex.maxHits + 50)
        let msg = message(id: 1, type: .assistant, content: content)

        let (hits, truncated) = TranscriptSearchIndex.hits(in: [msg], query: "x")

        XCTAssertEqual(hits.count, TranscriptSearchIndex.maxHits)
        XCTAssertTrue(truncated)
    }

    func testHitsBelowTheCapAreNotReportedAsTruncated() {
        let msg = message(id: 1, type: .assistant, content: "needle")
        let (hits, truncated) = TranscriptSearchIndex.hits(in: [msg], query: "needle")
        XCTAssertEqual(hits.count, 1)
        XCTAssertFalse(truncated)
    }
}
