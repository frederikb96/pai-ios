import XCTest

@testable import PAIKit

/// Covers `TranscriptStore`'s merge, paging-window bookkeeping, LRU eviction and display
/// filtering — the state a view built on top of it must never have to re-derive.
///
/// Every method is `async` even where nothing inside it awaits anything: Linux XCTest's
/// generated test-discovery array crashes at runtime (a forced cast between `@MainActor
/// () -> ()` and `() -> ()`) for a `@MainActor`-annotated `XCTestCase` whose test methods are
/// *all* synchronous. Marking every one `async` sidesteps the whole class of bug — see
/// `TranscriptSendTests`, which already mixes sync and async methods without hitting it, and
/// `TranscriptHoldTests`'s doc comment for the same trap from the other direction.
@MainActor
final class TranscriptStoreTests: XCTestCase {

    private func message(
        id: Int,
        sessionId: String = "s1",
        type: MessageType = .user,
        subtype: String? = nil,
        outboxId: Int? = nil,
        content: String? = "hello",
        thinking: String? = nil,
        toolCalls: [ToolCall]? = nil
    ) -> Message {
        Message(
            id: id, sessionId: sessionId, type: type, subtype: subtype, outboxId: outboxId,
            timestamp: nil, content: content, thinking: thinking, toolCalls: toolCalls,
            toolResult: nil, hookSummary: nil, tokens: nil, origin: nil, originMeta: nil, createdAt: nil
        )
    }

    // MARK: - Merge

    /// A batch replaying rows already in the store (an SSE reconnect) must not duplicate them,
    /// and the result must stay sorted by id regardless of arrival order.
    func testMergeDedupesByIdAndSortsRegardlessOfArrivalOrder() async {
        let store = TranscriptStore()
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 3), message(id: 1)], requestedLimit: 300)
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 1), message(id: 2)], requestedLimit: 300)

        XCTAssertEqual(store.messages["s1"]?.map(\.id), [1, 2, 3])
    }

    /// Merging nothing new must not allocate a new array identity-worth of churn for callers
    /// diffing by reference — this is the one behavior a naive "always replace" merge gets wrong.
    func testMergingAlreadyPresentEntriesChangesNothing() async {
        XCTAssertEqual(
            TranscriptStore.merged([message(id: 1)], with: [message(id: 1)]).map(\.id),
            [1]
        )
    }

    // MARK: - Bootstrap / paging window

    func testBootstrapHasOlderOnlyWhenTheFullPageCameBack() async {
        let store = TranscriptStore()
        store.applyBootstrap(sessionId: "s1", entries: (1...300).map { message(id: $0) }, requestedLimit: 300)
        XCTAssertTrue(store.window(for: "s1").hasOlder)

        let store2 = TranscriptStore()
        store2.applyBootstrap(sessionId: "s1", entries: (1...299).map { message(id: $0) }, requestedLimit: 300)
        XCTAssertFalse(store2.window(for: "s1").hasOlder)
    }

    /// `oldestLoadedId` must track across pages, not just within one — a second, older page
    /// looking back further must still lower it.
    func testOldestLoadedIdLowersAcrossSuccessivePages() async {
        let store = TranscriptStore()
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 100), message(id: 150)], requestedLimit: 150)
        XCTAssertEqual(store.window(for: "s1").oldestLoadedId, 100)

        store.prependOlder(sessionId: "s1", entries: [message(id: 40), message(id: 60)], requestedLimit: 150)
        XCTAssertEqual(store.window(for: "s1").oldestLoadedId, 40)
    }

    func testLoadingOlderClearsAStalePriorErrorOnEntryOnly() async {
        let store = TranscriptStore()
        store.setOlderError("s1", error: "boom")
        XCTAssertEqual(store.window(for: "s1").olderError, "boom")

        store.setLoadingOlder("s1", loading: true)
        XCTAssertNil(store.window(for: "s1").olderError, "entering a load should clear a stale error")
    }

    func testPrependOlderClearsLoadingAndError() async {
        let store = TranscriptStore()
        store.setLoadingOlder("s1", loading: true)
        store.prependOlder(sessionId: "s1", entries: [message(id: 5)], requestedLimit: 150)

        let win = store.window(for: "s1")
        XCTAssertFalse(win.loadingOlder)
        XCTAssertNil(win.olderError)
    }

    func testMaxMessageIdIsTheHighestIdLoadedForThatSessionOnly() async {
        let store = TranscriptStore()
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 5), message(id: 9)], requestedLimit: 300)
        store.applyBootstrap(sessionId: "s2", entries: [message(id: 200)], requestedLimit: 300)

        XCTAssertEqual(store.maxMessageId(for: "s1"), 9)
        XCTAssertEqual(store.maxMessageId(for: "s2"), 200)
        XCTAssertNil(store.maxMessageId(for: "unknown"))
    }

    // MARK: - LRU eviction

    /// The 6th distinct session touched must evict the least-recently-touched one, not an
    /// arbitrary one — and evicting it must drop its window too, so a re-visit re-bootstraps
    /// from the tail instead of resuming stale paging state.
    func testSixthSessionEvictsTheLeastRecentlyTouchedOne() async {
        let store = TranscriptStore()
        for index in 1...5 {
            store.applyBootstrap(
                sessionId: "s\(index)", entries: [message(id: index, sessionId: "s\(index)")], requestedLimit: 300)
        }
        XCTAssertNotNil(store.messages["s1"])

        store.applyBootstrap(sessionId: "s6", entries: [message(id: 6, sessionId: "s6")], requestedLimit: 300)

        XCTAssertNil(store.messages["s1"], "the least-recently-touched session should have been evicted")
        XCTAssertEqual(store.window(for: "s1"), .empty, "an evicted session's window must not survive it")
        XCTAssertNotNil(store.messages["s6"])
        XCTAssertEqual(store.messages.count, 5)
    }

    /// Touching an old session again (a batch arriving for it) must move it to the back of the
    /// eviction order — proving eviction tracks *access*, not creation order.
    func testTouchingASessionAgainProtectsItFromEviction() async {
        let store = TranscriptStore()
        for index in 1...5 {
            store.applyBootstrap(
                sessionId: "s\(index)", entries: [message(id: index, sessionId: "s\(index)")], requestedLimit: 300)
        }
        // Re-touch s1 via a live batch, same as an SSE event would.
        store.applySseBatch(
            sessionId: "s1", event: SseBatchEvent(entries: [message(id: 999, sessionId: "s1")], sessionTokens: nil))

        store.applyBootstrap(sessionId: "s6", entries: [message(id: 6, sessionId: "s6")], requestedLimit: 300)

        XCTAssertNotNil(
            store.messages["s1"], "a recently-touched session was evicted instead of the actually-oldest one")
        XCTAssertNil(store.messages["s2"], "s2, never re-touched, should be the one evicted")
    }

    /// `evictOldSessions`'s own doc comment promises it drops "messages, window and send-tracking
    /// state" — `pendingMessages` and `delivery` used to survive it regardless, so revisiting an
    /// evicted session before its next status event replayed a stale pending-send as a phantom
    /// "queued" bubble under a transcript that had already moved on to other messages entirely.
    func testEvictingASessionDropsItsPendingSendsAndDeliveryStateToo() async {
        let store = TranscriptStore()
        let send = Task<PostMessageResponse, Error> {
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            return PostMessageResponse(sessionId: "s1", messageId: 1)
        }
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 1, sessionId: "s1")], requestedLimit: 300)
        store.trackSend(sessionId: "s1", text: "hello", send: send)
        store.setDelivery(sessionId: "s1", pendingSends: [PendingSend(id: 2, text: "hi")], lastError: "boom")
        XCTAssertFalse(store.pendingBubbleTexts(sessionId: "s1").isEmpty, "the send must be tracked before eviction")

        for index in 2...6 {
            store.applyBootstrap(
                sessionId: "s\(index)", entries: [message(id: index, sessionId: "s\(index)")], requestedLimit: 300)
        }

        XCTAssertNil(store.messages["s1"], "s1 should have been the one evicted")
        XCTAssertTrue(
            store.pendingBubbleTexts(sessionId: "s1").isEmpty,
            "an evicted session's pending sends must not survive it")
        XCTAssertEqual(store.delivery(for: "s1"), .empty, "an evicted session's delivery state must not survive it")
        send.cancel()
    }

    // MARK: - SSE application

    func testSseInitAndBatchMergeIntoTheSameWindowSseSessionTokensUpdate() async {
        let store = TranscriptStore()
        store.applySseInit(
            sessionId: "s1",
            event: SseInitEvent(entries: [message(id: 1)], cursor: 1, hasMore: false, sessionTokens: 100)
        )
        store.applySseBatch(
            sessionId: "s1",
            event: SseBatchEvent(entries: [message(id: 2)], sessionTokens: 150)
        )

        XCTAssertEqual(store.messages["s1"]?.map(\.id), [1, 2])
        XCTAssertEqual(store.sessionTokens["s1"], 150)
    }

    /// `applySseInit` calls `evictOldSessions()`; `applySseBatch` used not to, even though
    /// `touch()` still grew `sessionAccessOrder` on every batch — a session that only ever
    /// receives live batches (never a fresh bootstrap or init) could push the cache past
    /// ``TranscriptStore``'s cap without ever being trimmed back down.
    func testApplySseBatchEnforcesTheCacheCapEvenWithoutABootstrapOrInit() async {
        let store = TranscriptStore()
        for index in 1...6 {
            store.applySseBatch(
                sessionId: "s\(index)",
                event: SseBatchEvent(entries: [message(id: index, sessionId: "s\(index)")], sessionTokens: nil)
            )
        }

        XCTAssertEqual(store.messages.count, 5, "a batch-only path must still respect the session cache cap")
        XCTAssertNil(store.messages["s1"], "the least-recently-touched session should have been evicted")
    }

    func testSseStatusDerivesIsProcessingFromPendingOrActiveOnly() async {
        let store = TranscriptStore()
        store.applySseStatus(
            sessionId: "s1",
            event: SseStatusEvent(
                status: .active, state: nil, blocker: nil, working: nil,
                queued: nil, queuedTexts: nil, pendingSends: nil, lastError: nil
            )
        )
        XCTAssertTrue(store.isProcessing(for: "s1"))

        store.applySseStatus(
            sessionId: "s1",
            event: SseStatusEvent(
                status: .completed, state: nil, blocker: nil, working: nil,
                queued: nil, queuedTexts: nil, pendingSends: nil, lastError: nil
            )
        )
        XCTAssertFalse(store.isProcessing(for: "s1"))
    }

    /// The scalar these two used to be showed a session that had just been switched to whatever
    /// the previous session's stream last reported, until its own first status/connect event
    /// landed. Keyed by session, a session that has reported nothing yet must read as idle and
    /// disconnected regardless of what another session is doing right now.
    func testIsProcessingAndSseConnectedAreKeyedPerSessionNotGlobal() async {
        let store = TranscriptStore()
        store.applySseStatus(
            sessionId: "s1",
            event: SseStatusEvent(
                status: .active, state: nil, blocker: nil, working: nil,
                queued: nil, queuedTexts: nil, pendingSends: nil, lastError: nil
            )
        )
        store.setSseConnected(sessionId: "s1", connected: true)

        XCTAssertTrue(store.isProcessing(for: "s1"))
        XCTAssertTrue(store.sseConnected(for: "s1"))
        XCTAssertFalse(
            store.isProcessing(for: "s2"), "a session with no status event yet must not inherit s1's spinner")
        XCTAssertFalse(
            store.sseConnected(for: "s2"), "a session with no connect event yet must not inherit s1's connection")
    }

    // MARK: - Display filtering

    /// The one place JS truthiness bites: whitespace-only content/thinking must still count as
    /// empty, the same as the web's `.trim()` check — a plain `!= nil` port would keep a row that
    /// should be dropped.
    func testDisplayMessagesDropsAssistantEntriesWithNoRealContent() async {
        let empty = message(id: 1, type: .assistant, content: "   ", thinking: "  ")
        let withContent = message(id: 2, type: .assistant, content: "hi")
        let withToolCall = message(
            id: 3, type: .assistant, content: nil, toolCalls: [ToolCall(id: "t", name: "Bash", input: [:])]
        )
        let nonAssistantEmpty = message(id: 4, type: .user, content: nil)

        let displayed = TranscriptStore.displayMessages([empty, withContent, withToolCall, nonAssistantEmpty])

        XCTAssertEqual(displayed.map(\.id), [2, 3, 4])
    }
}
