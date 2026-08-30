import XCTest

@testable import PAIKit

/// The session cache stays capped no matter which stream event arrives.
///
/// Both paths are asserted, because the cap used to depend on which one a caller happened to
/// route to: only the init path evicted, so a run of sessions that streamed without ever
/// bootstrapping grew without limit, and nothing failed. The two are now equivalent in that
/// respect, and these tests are what stops one of them quietly losing the call again.
///
/// Every method is `async` for the same Linux test-discovery trap `TranscriptStoreTests`'s doc
/// comment describes.
@MainActor
final class ScrollWiringSseInitEvictionTests: XCTestCase {

    private func message(id: Int, sessionId: String) -> Message {
        Message(
            id: id, sessionId: sessionId, type: .user, subtype: nil, outboxId: nil, timestamp: nil, content: "hello",
            thinking: nil, toolCalls: nil, toolResult: nil, hookSummary: nil, tokens: nil, origin: nil,
            originMeta: nil, createdAt: nil)
    }

    func testSseInitEvictsTheLeastRecentlyTouchedSessionTheSameWayBootstrapDoes() async {
        let store = TranscriptStore()
        for index in 1...5 {
            store.applySseInit(
                sessionId: "s\(index)",
                event: SseInitEvent(
                    entries: [message(id: index, sessionId: "s\(index)")], cursor: index, hasMore: false,
                    sessionTokens: nil))
        }
        XCTAssertNotNil(store.messages["s1"])

        store.applySseInit(
            sessionId: "s6",
            event: SseInitEvent(
                entries: [message(id: 6, sessionId: "s6")], cursor: 6, hasMore: false, sessionTokens: nil))

        XCTAssertNil(store.messages["s1"], "a real init event must evict the same way applyBootstrap does")
        XCTAssertEqual(store.messages.count, 5)
    }

    /// The path that used to be the leak: batch events alone must still respect the cap.
    func testSseBatchAloneAlsoEvictsPastTheCap() async {
        let store = TranscriptStore()
        for index in 1...5 {
            store.applySseBatch(
                sessionId: "s\(index)",
                event: SseBatchEvent(entries: [message(id: index, sessionId: "s\(index)")], sessionTokens: nil))
        }

        store.applySseBatch(
            sessionId: "s6",
            event: SseBatchEvent(entries: [message(id: 6, sessionId: "s6")], sessionTokens: nil))

        XCTAssertNil(
            store.messages["s1"], "a streamed batch must evict too — a cap only one path enforces is not a cap")
        XCTAssertEqual(store.messages.count, 5)
    }
}
