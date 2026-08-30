import XCTest

@testable import PAIKit

/// Pins down the consequence of a real wiring decision in `TranscriptCollectionViewController`:
/// its `PaiSseClient.Callbacks.onInit` must route to `TranscriptStore.applySseInit(sessionId:event:)`,
/// never to `applySseBatch(sessionId:event:)` — the two differ by exactly one call,
/// `evictOldSessions()` (see `applySseInit`'s own doc comment), which only the real init event
/// should trigger. Routing `onInit` to `applySseBatch` instead — which is what shipped before this
/// was wired up — compiles, passes every existing test, and only shows up as an LRU cap that never
/// actually evicts for a run of sessions that only ever streamed, never bootstrapped.
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

    /// The reverse case, pinned down deliberately: `applySseBatch` alone never evicts, which is
    /// exactly why an init event landing there instead of at `applySseInit` would be silent —
    /// nothing fails, the cap just stops being enforced.
    func testSseBatchAloneNeverEvictsEvenPastTheCap() async {
        let store = TranscriptStore()
        for index in 1...5 {
            store.applySseBatch(
                sessionId: "s\(index)",
                event: SseBatchEvent(entries: [message(id: index, sessionId: "s\(index)")], sessionTokens: nil))
        }

        store.applySseBatch(
            sessionId: "s6",
            event: SseBatchEvent(entries: [message(id: 6, sessionId: "s6")], sessionTokens: nil))

        XCTAssertNotNil(
            store.messages["s1"], "batch alone must not evict — that gap is what makes routing init correctly matter")
        XCTAssertEqual(
            store.messages.count, 6, "the cap was exceeded here on purpose, to show what batch-only never catches")
    }
}
