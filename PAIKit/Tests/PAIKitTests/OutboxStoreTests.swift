import XCTest

@testable import PAIKit

/// A rendezvous a send can be held on, so a test can prove ordering rather than infer it — same
/// shape as `DraftStoreTests`'s own `Gate`.
private actor SendGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        let waiting = continuations
        continuations = []
        for continuation in waiting { continuation.resume() }
    }
}

private final class FakeOutboxApi: OutboxSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(clientMessageId: String, sessionId: String?, message: String, draftAttachmentIds: [String])] =
        []
    var calls: [(clientMessageId: String, sessionId: String?, message: String, draftAttachmentIds: [String])] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    var gate: SendGate?
    /// Consecutive attempts left to fail with the given error before succeeding — keyed by
    /// nothing, since a test using this only ever drives one entry at a time.
    var failuresRemaining = 0
    var failureToThrow: PaiError = .transport("no network")
    var result: PostMessageResponse = PostMessageResponse(sessionId: "s1", messageId: 42)

    private func record(
        _ entry: (clientMessageId: String, sessionId: String?, message: String, draftAttachmentIds: [String])
    ) {
        lock.lock()
        _calls.append(entry)
        lock.unlock()
    }

    private func consumeFailure() -> PaiError? {
        lock.lock()
        defer { lock.unlock() }
        guard failuresRemaining > 0 else { return nil }
        failuresRemaining -= 1
        return failureToThrow
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], sessionType: String?, workingDir: String?, agent: String?, model: String?,
        thinking: String?, clientMode: String?
    ) async throws -> PostMessageResponse {
        record(
            (
                clientMessageId: clientMessageId, sessionId: sessionId, message: message,
                draftAttachmentIds: draftAttachmentIds
            ))
        if let gate { await gate.wait() }
        if let error = consumeFailure() { throw error }
        return result
    }
}

@MainActor
final class OutboxStoreTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - Basic send

    func testAQueuedEntryIsSentAndMovesToSent() async {
        let sending = FakeOutboxApi()
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello")

        store.enqueue(entry)

        await waitUntil { store.entries.first?.state == .sent }
        XCTAssertEqual(store.entries.first?.result, OutboxResult(sessionId: "s1", messageId: 42))
        XCTAssertEqual(sending.calls.count, 1)
        XCTAssertEqual(sending.calls[0].clientMessageId, entry.clientMessageId)
    }

    /// `client_message_id` is never re-minted for a retry — resending the identical id is the
    /// whole point of the idempotency the server enforces.
    func testARetriedSendReusesTheSameClientMessageId() async {
        let sending = FakeOutboxApi()
        sending.failuresRemaining = 2
        sending.failureToThrow = .transport("offline")
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello")

        store.enqueue(entry)

        await waitUntil(timeout: 5) { store.entries.first?.state == .sent }
        let ids = Set(sending.calls.map(\.clientMessageId))
        XCTAssertEqual(ids, [entry.clientMessageId], "every attempt must carry the same id")
        XCTAssertEqual(sending.calls.count, 3, "two failures, then the retry that succeeds")
    }

    /// A non-retryable failure (anything but a transport error, a 5xx, or 429) lands `.failed`
    /// rather than retrying forever.
    func testANonRetryableFailureLandsInFailedState() async {
        let sending = FakeOutboxApi()
        sending.failuresRemaining = 1
        sending.failureToThrow = .detail("message too long", statusCode: 413)
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello")

        store.enqueue(entry)

        await waitUntil { store.entries.first?.state == .failed }
        XCTAssertEqual(store.entries.first?.lastError, "message too long")
        XCTAssertEqual(sending.calls.count, 1, "a non-retryable failure must not be attempted again")
    }

    /// `409 session_not_active` is a resume-and-retry signal, not a hard failure — the entry must
    /// stay queued and eventually succeed once the pod has resumed the session.
    func testSessionNotActiveIsRetriedRatherThanFailed() async {
        let sending = FakeOutboxApi()
        sending.failuresRemaining = 1
        sending.failureToThrow = .detail("session_not_active", statusCode: 409)
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello")

        store.enqueue(entry)

        await waitUntil(timeout: 5) { store.entries.first?.state == .sent }
        XCTAssertEqual(sending.calls.count, 2)
    }

    // MARK: - Ordering

    /// One FIFO worker per target — two sends to the SAME session must reach the server in the
    /// order they were pressed, never interleaved or reordered.
    func testTwoEntriesForTheSameSessionAreSentInOrder() async {
        let sending = FakeOutboxApi()
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())

        store.enqueue(OutboxEntry(target: .session(sessionId: "s1"), text: "first"))
        store.enqueue(OutboxEntry(target: .session(sessionId: "s1"), text: "second"))

        await waitUntil { store.entries.allSatisfy { $0.state == .sent } }
        XCTAssertEqual(sending.calls.map(\.message), ["first", "second"])
    }

    /// Entries for two DIFFERENT sessions have independent workers — one gated send must never
    /// block a send to an unrelated target.
    func testEntriesForDifferentSessionsDoNotBlockEachOther() async {
        let sending = FakeOutboxApi()
        let gate = SendGate()
        sending.gate = gate
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())

        store.enqueue(OutboxEntry(target: .session(sessionId: "s1"), text: "held"))
        await waitUntil { sending.calls.contains { $0.sessionId == "s1" } }

        // A second target's send must reach the server even while the first is gated shut —
        // if it shared one worker, this would never fire until the gate opened.
        sending.gate = nil
        store.enqueue(OutboxEntry(target: .session(sessionId: "s2"), text: "unrelated"))
        await waitUntil { store.entries.first { $0.target.sessionId == "s2" }?.state == .sent }

        await gate.open()
        await waitUntil { store.entries.first { $0.target.sessionId == "s1" }?.state == .sent }
    }

    // MARK: - draftAttachmentIds

    func testDraftAttachmentIdsAreClaimedExplicitly() async {
        let sending = FakeOutboxApi()
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        store.enqueue(
            OutboxEntry(target: .session(sessionId: "s1"), text: "photo attached", draftAttachmentIds: ["a1", "a2"]))

        await waitUntil { store.entries.first?.state == .sent }
        XCTAssertEqual(sending.calls.first?.draftAttachmentIds, ["a1", "a2"])
    }

    // MARK: - Inline files

    func testInlineFileBytesAreWrittenAndReadBackForSending() async {
        let sending = FakeOutboxApi()
        let storage = OutboxInMemoryStorage()
        let store = OutboxStore(api: sending, storage: storage)
        let inlineFile = OutboxInlineFile(localId: "local-1", filename: "photo.jpg", mimeType: "image/jpeg")
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "", inlineFiles: [inlineFile])

        store.enqueue(entry, inlineFileData: ["local-1": Data("bytes".utf8)])

        await waitUntil { store.entries.first?.state == .sent }
        XCTAssertEqual(storage.readInlineFile(localId: "local-1"), nil, "the bytes are removed once sent")
    }

    // MARK: - onSent

    func testOnSentFiresOnceTheEntryReachesTheServer() async {
        let sending = FakeOutboxApi()
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        var seen: OutboxEntry?
        store.onSent = { entry in seen = entry }

        store.enqueue(OutboxEntry(target: .session(sessionId: "s1"), text: "hello"))

        await waitUntil { seen != nil }
        XCTAssertEqual(seen?.state, .sent)
    }

    // MARK: - retry() / discard()

    func testRetryReQueuesAFailedEntryUnderTheSameId() async {
        let sending = FakeOutboxApi()
        sending.failuresRemaining = 1
        sending.failureToThrow = .detail("refused", statusCode: 400)
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage())
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello")
        store.enqueue(entry)
        await waitUntil { store.entries.first?.state == .failed }

        store.retry(id: entry.id)

        await waitUntil { store.entries.first?.state == .sent }
        XCTAssertEqual(sending.calls.map(\.clientMessageId), [entry.clientMessageId, entry.clientMessageId])
    }

    func testDiscardRemovesTheEntryAndItsInlineBytes() async {
        let sending = FakeOutboxApi()
        sending.failuresRemaining = 1
        sending.failureToThrow = .detail("refused", statusCode: 400)
        let storage = OutboxInMemoryStorage()
        let store = OutboxStore(api: sending, storage: storage)
        let inlineFile = OutboxInlineFile(localId: "local-1", filename: "x.txt", mimeType: "text/plain")
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello", inlineFiles: [inlineFile])
        store.enqueue(entry, inlineFileData: ["local-1": Data("x".utf8)])
        await waitUntil { store.entries.first?.state == .failed }

        store.discard(id: entry.id)

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertNil(storage.readInlineFile(localId: "local-1"))
    }

    // MARK: - Surviving a relaunch

    /// A `queued` entry, written to disk by a process that never got to send it (an app kill right
    /// after `enqueue`), must still be here and still send once a fresh store reads the same
    /// storage back — this is the whole durability guarantee, independent of any particular
    /// `OutboxStore` instance's in-memory state.
    func testAQueuedEntrySurvivesAFreshStoreConstructedAgainstTheSameStorage() async {
        let storage = OutboxInMemoryStorage()
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "typed before the kill")
        storage.saveEntries([entry])

        let sending = FakeOutboxApi()
        let freshProcess = OutboxStore(api: sending, storage: storage)

        await waitUntil { freshProcess.entries.first?.state == .sent }
        XCTAssertEqual(freshProcess.entries.first?.text, "typed before the kill")
        XCTAssertEqual(sending.calls.first?.clientMessageId, entry.clientMessageId)
    }

    /// An entry the previous process had already marked `sending` when it died must be retried —
    /// never left stuck, since the POST it was mid-flight on is safely idempotent.
    func testAnEntryFoundSendingAtStartupIsRetried() async {
        let storage = OutboxInMemoryStorage()
        let entry = OutboxEntry(
            target: .session(sessionId: "s1"), text: "mid-flight when the app died", state: .sending)
        storage.saveEntries([entry])

        let sending = FakeOutboxApi()
        let store = OutboxStore(api: sending, storage: storage)

        await waitUntil { store.entries.first?.state == .sent }
        XCTAssertEqual(sending.calls.first?.clientMessageId, entry.clientMessageId)
    }

    // MARK: - retryNow()

    /// Skips the backoff wait outright rather than merely shortening it — proved against a
    /// scheduler that would otherwise hang the test for real wall-clock seconds.
    func testRetryNowSkipsAWaitingBackoff() async {
        let sending = FakeOutboxApi()
        sending.failuresRemaining = 1
        sending.failureToThrow = .transport("offline")
        // A scheduler whose sleep never resolves on its own — only `retryNow()`'s cancellation
        // can end it early. If it did not, this test would hang until its own timeout instead of
        // passing quickly.
        struct NeverResolvingScheduler: DraftScheduler {
            func sleep(seconds: TimeInterval) async throws {
                try await Task.sleep(nanoseconds: 3_600_000_000_000)
            }
        }
        let store = OutboxStore(api: sending, storage: OutboxInMemoryStorage(), scheduler: NeverResolvingScheduler())
        store.enqueue(OutboxEntry(target: .session(sessionId: "s1"), text: "hello"))
        // Wait for the failed attempt's own bookkeeping to finish, not merely for the request to
        // have been recorded — `backoffTasks` is only populated once the retry has actually been
        // scheduled, and `attempts` moving to 1 happens in the same synchronous stretch as that.
        await waitUntil { store.entries.first?.attempts == 1 }

        store.retryNow()

        await waitUntil(timeout: 5) { store.entries.first?.state == .sent }
        XCTAssertEqual(sending.calls.count, 2)
    }

    // MARK: - draftKey

    /// What "Put back in composer" writes onto — the session's own key for an ordinary send.
    func testDraftKeyIsTheSessionIdForAnOrdinarySend() {
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "hello")
        XCTAssertEqual(entry.draftKey, "s1")
    }

    /// A send made before the session it creates exists yet has no session id to key on — the
    /// new-session composer's own draft key instead.
    func testDraftKeyIsTheNewSessionKeyForAPreLaunchSend() {
        let entry = OutboxEntry(
            target: .newSession(agent: nil, sessionType: nil, workingDir: nil, model: nil, thinking: nil),
            text: "hello")
        XCTAssertEqual(entry.draftKey, DraftKey.newSession)
    }
}
