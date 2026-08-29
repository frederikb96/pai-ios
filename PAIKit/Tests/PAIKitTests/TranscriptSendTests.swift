import XCTest

@testable import PAIKit

/// Covers the pending-send / delivery-confirmation state machine — the part flagged as highest
/// risk to get subtly wrong, since a false pass here (a bubble that never clears, or clears too
/// early) is invisible until Freddy is staring at a stuck or doubled message.
@MainActor
final class TranscriptSendTests: XCTestCase {

    private struct TestError: Error {}

    private func message(id: Int, sessionId: String = "s1", outboxId: Int? = nil) -> Message {
        Message(
            id: id, sessionId: sessionId, type: .user, subtype: nil, outboxId: outboxId,
            timestamp: nil, content: "hi", thinking: nil, toolCalls: nil, toolResult: nil,
            hookSummary: nil, tokens: nil, origin: nil, originMeta: nil, createdAt: nil
        )
    }

    /// Polls the condition via yields rather than sleeping, so the test reports whatever the
    /// condition actually settles to (including "never") instead of a fixed-timeout guess.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - trackSend

    /// The bubble must appear synchronously, before the send has had any chance to resolve —
    /// this is what lets a slow network never leave the composer looking like it did nothing.
    func testTrackSendShowsALocalBubbleImmediately() {
        let store = TranscriptStore()
        let send = Task<PostMessageResponse, Error> {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return PostMessageResponse(sessionId: "s1", messageId: 1)
        }
        store.trackSend(sessionId: "s1", text: "hello", send: send)

        XCTAssertEqual(store.pendingBubbleTexts(sessionId: "s1"), ["hello"])
        send.cancel()
    }

    func testTrackSendStampsOutboxIdOnSuccess() async {
        let store = TranscriptStore()
        let send = Task<PostMessageResponse, Error> { PostMessageResponse(sessionId: "s1", messageId: 42) }
        store.trackSend(sessionId: "s1", text: "hello", send: send)

        await waitUntil { store.pendingMessages["s1"]?.first?.outboxId == 42 }
        XCTAssertEqual(store.pendingMessages["s1"]?.first?.outboxId, 42)
    }

    /// A bubble with no row behind it can never be told it arrived, so a failed send must drop
    /// it outright rather than leave it stuck forever.
    func testTrackSendDropsTheBubbleWhenTheSendFails() async {
        let store = TranscriptStore()
        let send = Task<PostMessageResponse, Error> { throw TestError() }
        store.trackSend(sessionId: "s1", text: "hello", send: send)

        await waitUntil { store.pendingMessages["s1"]?.isEmpty ?? true }
        XCTAssertEqual(store.pendingMessages["s1"], [])
    }

    /// A fast turn can have its confirming transcript entry land before the send request itself
    /// has answered — `trackSend` re-reconciles after stamping the outbox id specifically to
    /// catch that.
    func testTrackSendReconcilesAgainstAnEntryThatArrivedBeforeTheSendAnswered() async {
        let store = TranscriptStore()
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 1, outboxId: 42)], requestedLimit: 300)
        let send = Task<PostMessageResponse, Error> { PostMessageResponse(sessionId: "s1", messageId: 42) }

        store.trackSend(sessionId: "s1", text: "hello", send: send)

        await waitUntil { store.pendingMessages["s1"]?.isEmpty ?? true }
        XCTAssertEqual(store.pendingMessages["s1"], [], "the already-arrived entry should have reconciled the bubble")
    }

    // MARK: - reconcilePending

    func testReconcilePendingDropsOnlyBubblesTheTranscriptConfirms() {
        let store = TranscriptStore()
        store.pendingMessages["s1"] = [
            PendingMessage(localId: 1, text: "a", outboxId: 10),
            PendingMessage(localId: 2, text: "b", outboxId: 20),
        ]
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 1, outboxId: 10)], requestedLimit: 300)

        store.reconcilePending("s1")

        XCTAssertEqual(store.pendingMessages["s1"]?.map(\.localId), [2])
    }

    // MARK: - setDelivery / bridging

    /// The server's list must never draw a bubble a local one already names — otherwise the same
    /// message would appear twice for as long as the server's snapshot lags the send.
    func testSetDeliveryDropsALocalBubbleTheServerListNowNames() {
        let store = TranscriptStore()
        store.pendingMessages["s1"] = [PendingMessage(localId: 1, text: "a", outboxId: 10)]

        store.setDelivery(sessionId: "s1", pendingSends: [PendingSend(id: 10, text: "a")], lastError: nil)

        XCTAssertEqual(store.pendingMessages["s1"], [])
    }

    /// A send the list does NOT name must be left alone — a status event produced before the
    /// send reached the database cannot know about it yet.
    func testSetDeliveryLeavesAnUnnamedLocalBubbleAlone() {
        let store = TranscriptStore()
        store.pendingMessages["s1"] = [PendingMessage(localId: 1, text: "a", outboxId: 10)]

        store.setDelivery(sessionId: "s1", pendingSends: [], lastError: nil)

        XCTAssertEqual(store.pendingMessages["s1"]?.map(\.localId), [1])
    }

    // MARK: - pendingBubbleTexts (the bridging composition)

    /// While a bubble's send has not yet answered (`outboxId == nil`), the server's list is held
    /// back entirely — otherwise a message could draw once from each side.
    func testPendingBubbleTextsHoldsBackTheServerListWhileALocalBubbleIsNameless() {
        let store = TranscriptStore()
        store.pendingMessages["s1"] = [PendingMessage(localId: 1, text: "typing", outboxId: nil)]
        store.delivery["s1"] = TranscriptDelivery(
            pendingSends: [PendingSend(id: 99, text: "server side")], lastError: nil)

        XCTAssertEqual(store.pendingBubbleTexts(sessionId: "s1"), ["typing"])
    }

    /// Once every local bubble is named, the server's list draws too — minus whatever a local
    /// bubble or the transcript itself already accounts for.
    func testPendingBubbleTextsComposesServerAndLocalOnceNotBridging() {
        let store = TranscriptStore()
        store.pendingMessages["s1"] = [PendingMessage(localId: 1, text: "mine", outboxId: 5)]
        store.delivery["s1"] = TranscriptDelivery(
            pendingSends: [PendingSend(id: 5, text: "mine"), PendingSend(id: 6, text: "other device")],
            lastError: nil
        )

        // id 5 is de-duplicated against the local bubble that already names it; id 6 draws from
        // the server side; the local bubble draws once, last, matching the web's ordering.
        XCTAssertEqual(store.pendingBubbleTexts(sessionId: "s1"), ["other device", "mine"])
    }

    /// A send the transcript itself has already confirmed must not draw from the server list —
    /// the transcript in hand retires it without waiting for the server to say it again.
    func testPendingBubbleTextsExcludesServerEntriesTheTranscriptAlreadyConfirmed() {
        let store = TranscriptStore()
        store.applyBootstrap(sessionId: "s1", entries: [message(id: 1, outboxId: 7)], requestedLimit: 300)
        store.delivery["s1"] = TranscriptDelivery(
            pendingSends: [PendingSend(id: 7, text: "already landed")], lastError: nil)

        XCTAssertEqual(store.pendingBubbleTexts(sessionId: "s1"), [])
    }
}
