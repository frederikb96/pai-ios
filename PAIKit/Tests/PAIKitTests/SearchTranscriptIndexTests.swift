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

    /// The index always forces every card open (see the type's own doc comment) — a real render
    /// with the reader's expand preferences would show none of this text, but the index has to
    /// find it anyway, or a hit inside a collapsed tool result could never be searched to.
    func testHitsFindsTextBehindWhatWouldBeACollapsedCard() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("grep needle file.txt")])]
        let msg = message(id: 1, type: .assistant, toolCalls: calls)

        let (hits, _) = TranscriptSearchIndex.hits(in: [msg], query: "needle")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].messageId, 1)
        XCTAssertEqual(hits[0].cardIndex, 0)
        XCTAssertEqual(hits[0].blockIndex, 0)
    }

    /// A hit's `expandKey` must be exactly what opens its card — otherwise a caller who force-opens
    /// by that key would open the wrong thing, or nothing at all.
    func testHitsExpandKeyMatchesWhatWouldActuallyOpenTheCard() {
        let calls = [ToolCall(id: "1", name: "Bash", input: ["command": .string("echo needle")])]
        let msg = message(id: 1, type: .assistant, toolCalls: calls)

        let (hits, _) = TranscriptSearchIndex.hits(in: [msg], query: "needle")

        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].expandKey, MessageRouting.toolExpandKey(name: "Bash", isResult: false))
    }

    /// A message text-searchable by ``TranscriptRowPlan/cards(for:isExpanded:)`` without any
    /// expand key at all (a plain bubble) must still produce a hit, with `expandKey == nil`.
    func testHitsOnAnUncollapsibleBubbleCarryNoExpandKey() {
        let msg = message(id: 1, type: .user, content: "find the needle here")
        let (hits, _) = TranscriptSearchIndex.hits(in: [msg], query: "needle")
        XCTAssertEqual(hits.count, 1)
        XCTAssertNil(hits[0].expandKey)
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
