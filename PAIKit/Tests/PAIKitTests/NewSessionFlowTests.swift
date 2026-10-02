import Foundation
import XCTest

@testable import PAIKit

/// A short sleep rather than none: `OutboxStore`'s worker loop re-reads its queue after every
/// backoff, so a scheduler that resolves instantly turns a still-failing entry into a hot spin
/// that starves the assertion waiting on it.
private struct BriefScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Fails its first `failuresRemaining` attempts, then answers — the shape a send made with no
/// link has, healing when the link returns.
private final class FlakyOutboxApi: OutboxSending, @unchecked Sendable {
    private let lock = NSLock()
    private var _attempts = 0
    var attempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _attempts
    }

    var failuresRemaining = 0
    var failureToThrow: PaiError = .transport("no network")
    var response = PostMessageResponse(sessionId: "created-id", messageId: 7, duplicate: false, draftVersion: 11)

    /// Synchronous, because `NSLock` may not be held across a suspension point — the same split
    /// `OutboxStoreTests`' own fake uses.
    private func recordAttempt() -> PaiError? {
        lock.lock()
        defer { lock.unlock() }
        _attempts += 1
        guard failuresRemaining > 0 else { return nil }
        failuresRemaining -= 1
        return failureToThrow
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], sessionType: String?, workingDir: String?, agent: String?, model: String?,
        thinking: String?, clientMode: String?
    ) async throws -> PostMessageResponse {
        if let failure = recordAttempt() { throw failure }
        return response
    }
}

/// Answers nothing and records nothing — `DraftStore` only takes part here as the thing
/// `installHandover` records a consumed draft version onto.
private struct SilentDraftsApi: DraftsFetching {
    func getDrafts() async throws -> [Draft] { [] }
    func putDraft(
        key: String, text: String, deviceId: String?, sessionType: String?, workingDir: String?, model: String?,
        thinking: String?
    ) async throws -> DraftWriteResult {
        DraftWriteResult(key: key, version: 1, previousText: nil)
    }
    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        PaiDraftDeleteResult(key: key, version: 1, previousText: nil)
    }
    func addDraftAttachment(key: String, file: PaiFileUpload) async throws -> DraftAttachment {
        throw PaiError.transport("not used")
    }
    func removeDraftAttachment(key: String, attachmentId: String) async throws {}
}

/// The path from pressing Send on the new-session screen to standing in the session it created.
///
/// Every test here installs the real handover (`OutboxStore.installHandover`) rather than a
/// closure of its own, because the join is what this covers: each half of it passes its own tests
/// whether or not anything connects them, and what the reader experiences is entirely the join.
@MainActor
final class NewSessionFlowTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private struct Harness {
        let outbox: OutboxStore
        let sessions: SessionListStore
        let drafts: DraftStore
        let handoff: NewSessionHandoff
        let create: CreateSessionStore
        let api: FlakyOutboxApi
        let listApi: FakeSessionListApi
    }

    private func makeHarness() -> Harness {
        let api = FlakyOutboxApi()
        let outbox = OutboxStore(api: api, storage: OutboxInMemoryStorage(), scheduler: BriefScheduler())
        let listApi = FakeSessionListApi()
        let sessions = SessionListStore(api: listApi)
        let drafts = DraftStore(api: SilentDraftsApi())
        let handoff = NewSessionHandoff()
        outbox.installHandover(drafts: drafts, sessions: sessions, handoff: handoff)
        return Harness(
            outbox: outbox, sessions: sessions, drafts: drafts, handoff: handoff,
            create: CreateSessionStore(
                machines: MachineStore(api: FakeMachineDirectoryApi()), api: FakeCreateSessionApi()),
            api: api, listApi: listApi)
    }

    private func session(id: String, title: String) -> Session {
        Session(
            id: id, sessionType: "fast", status: .active, state: .ready, blocker: nil, displayState: .done,
            title: title, titleLocked: nil, initialMessage: "hello", sessionTokens: 0, claudeSessionId: nil,
            idleTimeoutMinutes: nil, effectiveIdleTimeoutMinutes: nil, cseId: nil,
            createdAt: "2020-01-01T00:00:00.000000+00:00", updatedAt: "2020-01-01T00:00:00.000000+00:00",
            lastActivityAt: "2020-01-01T00:00:00.000000+00:00", workingDir: nil, agent: "vm", kind: .conversation,
            parentSessionId: nil, subagentName: nil, subagentType: nil, subagentDescription: nil,
            remoteControl: true, discovered: nil, projectId: nil, phaseId: nil, projectName: nil)
    }

    // MARK: - The send that lands

    /// The whole point of the flow: the session reaches the list AND its id reaches the screen
    /// that composed the message. The id is the half with no other route — the screen does not
    /// wait for the network, so a create whose id is handed to nobody leaves the reader standing
    /// on the new-session screen with the session already behind it.
    func testALandedSendPutsTheSessionInTheListAndHandsItsIdToTheScreen() async {
        let h = makeHarness()
        h.create.selectMachine("laptop")
        h.create.selectSessionType("fast")

        h.create.enqueueSend(message: "first message", outbox: h.outbox)

        await waitUntil { h.handoff.createdSessionID != nil }
        XCTAssertEqual(h.handoff.createdSessionID, "created-id")
        XCTAssertEqual(h.sessions.syncedSessions.first?.id, "created-id")
        XCTAssertEqual(h.sessions.syncedSessions.first?.initialMessage, "first message")
        XCTAssertEqual(h.sessions.syncedSessions.first?.agent, "laptop")
        XCTAssertEqual(h.sessions.syncedSessions.first?.sessionType, "fast")
    }

    /// Retired only after the handover, never before: nothing outside that closure can observe a
    /// `.sent` entry, so anything that tried to read one would find an empty queue and conclude
    /// the send had been removed.
    func testTheEntryIsGoneOnceItHasBeenHandedOver() async {
        let h = makeHarness()

        h.create.enqueueSend(message: "hello", outbox: h.outbox)

        await waitUntil { h.handoff.createdSessionID != nil }
        XCTAssertTrue(h.outbox.entries.isEmpty)
        XCTAssertTrue(h.outbox.newSessionEntries().isEmpty)
    }

    /// The draft version the send consumed — recorded by the same handover, for the same reason:
    /// the entry carrying it does not survive long enough for anyone else to read it.
    func testTheConsumedDraftVersionIsRecordedOnTheDraftTheSendCameFrom() async {
        let h = makeHarness()
        // The state a send leaves behind: the key exists and its text is gone. Flushed rather
        // than merely set, so no debounce or in-flight write is outstanding — `DraftStore` holds
        // off on recording a version against either, which is right and is not what this covers.
        h.drafts.setDraftText(key: DraftKey.newSession, text: "")
        await h.drafts.flush(key: DraftKey.newSession)

        h.create.enqueueSend(message: "typed", outbox: h.outbox)

        await waitUntil { h.handoff.createdSessionID != nil }
        XCTAssertEqual(h.drafts.draft(for: DraftKey.newSession).knownVersion, 11)
    }

    // MARK: - No link at the moment of sending

    /// With nothing reachable, the send is kept and stays *visible* — the new-session screen's
    /// own bubble list is `newSessionEntries()`, and it is the only place a message for a session
    /// that does not exist yet can be seen at all. Then it lands by itself and opens the session.
    func testASendWithNoLinkStaysVisibleAsAQueuedEntryAndOpensTheSessionWhenItLands() async {
        let h = makeHarness()
        h.api.failuresRemaining = 2

        h.create.enqueueSend(message: "sent from a tunnel", outbox: h.outbox)

        await waitUntil { h.api.attempts >= 1 }
        let waiting = h.outbox.newSessionEntries()
        XCTAssertEqual(waiting.count, 1, "a send with no link must still be somewhere the reader can see it")
        XCTAssertEqual(waiting.first?.text, "sent from a tunnel")
        XCTAssertNotEqual(waiting.first?.state, .sent)
        XCTAssertNil(h.handoff.createdSessionID, "nothing exists to open while the send is still waiting")

        await waitUntil(timeout: 5) { h.handoff.createdSessionID != nil }
        XCTAssertEqual(h.sessions.syncedSessions.first?.id, "created-id")
    }

    /// A refusal the server would repeat stops and says why, rather than retrying forever behind
    /// a screen with nothing on it. The entry stays in the reader's own queue carrying the reason.
    func testARefusedSendStaysVisibleCarryingItsReason() async {
        let h = makeHarness()
        h.api.failuresRemaining = 1
        h.api.failureToThrow = .detail("message too long", statusCode: 413)

        h.create.enqueueSend(message: "far too much", outbox: h.outbox)

        await waitUntil { h.outbox.newSessionEntries().first?.state == .failed }
        XCTAssertEqual(h.outbox.newSessionEntries().first?.lastError, "message too long")
        XCTAssertNil(h.handoff.createdSessionID)
        XCTAssertTrue(h.sessions.syncedSessions.isEmpty, "a refused send creates nothing")
    }

    // MARK: - The optimistic row

    /// The row is a guess, so it carries no version of its own — `isStaleVersion` compares the
    /// server's copy against whatever the held row claims, and a client-minted stamp even
    /// slightly ahead of the server's makes the real row read as stale and leaves the guess on
    /// screen indefinitely.
    func testTheOptimisticRowCarriesNoVersionSoTheServersOwnCopyAlwaysReplacesIt() async {
        let h = makeHarness()
        h.create.enqueueSend(message: "hello", outbox: h.outbox)
        await waitUntil { h.handoff.createdSessionID != nil }

        guard let guess = h.sessions.syncedSessions.first else { return XCTFail("no row was adopted") }
        // Stamped well in the past, which is the case that bites: a guess carrying a stamp of its
        // own from the phone's clock reads as newer than the truth.
        let serverCopy = session(id: "created-id", title: "Named by the server")

        XCTAssertFalse(
            SessionListStore.isStaleVersion(held: guess, incoming: serverCopy),
            "the server's copy must win over the guess whatever its own updated_at says")
    }

    /// The poll can bring the real row in before the send's own answer arrives. The row is left
    /// alone — but the id is still answered, because navigation must not depend on which of the
    /// two got there first.
    func testARowThePollAlreadyBroughtInIsNotDuplicatedAndTheIdIsStillHandedOver() async {
        let h = makeHarness()
        let listed = session(id: "created-id", title: "Already listed")
        await h.listApi.setGetSessionsResult { _ in .success(SessionsPage(sessions: [listed], nextCursor: nil)) }
        await h.sessions.ensureSessionLoaded(id: "created-id")
        XCTAssertEqual(h.sessions.syncedSessions.count, 1, "the fixture row has to be there for this to mean anything")
        let entry = OutboxEntry(
            target: .newSession(agent: "vm", sessionType: "fast", workingDir: nil, model: nil, thinking: nil),
            text: "hello", state: .sent,
            result: OutboxResult(sessionId: "created-id", messageId: 7, draftVersion: nil))

        let adopted = h.sessions.adoptCreatedSession(entry)

        XCTAssertEqual(adopted, "created-id", "the caller still has a session to open")
        XCTAssertEqual(h.sessions.syncedSessions.count, 1)
        XCTAssertEqual(h.sessions.syncedSessions.first?.title, "Already listed", "the real row is not overwritten")
    }

    /// An ordinary send to a session that already exists creates nothing and hands nothing over —
    /// the handover runs for every entry, so this is what keeps it from opening a screen on one.
    func testAnOrdinarySendToAnExistingSessionAdoptsNothing() async {
        let h = makeHarness()

        h.outbox.enqueue(OutboxEntry(target: .session(sessionId: "existing"), text: "hello"))

        await waitUntil { h.outbox.entries.isEmpty }
        XCTAssertNil(h.handoff.createdSessionID)
        XCTAssertTrue(h.sessions.syncedSessions.isEmpty)
    }

    // MARK: - The handoff's own one-shot rules

    func testACreatedSessionIsOfferedExactlyOnce() async {
        let handoff = NewSessionHandoff()
        handoff.created(sessionID: "created-id")

        XCTAssertEqual(handoff.consumeCreated(), "created-id")
        XCTAssertNil(handoff.consumeCreated(), "a second visit to the screen must not reopen it")
    }

    /// Dropping an offer nobody opened must not resurrect it on a later visit to the screen.
    func testWithdrawingAnUnopenedOfferClearsIt() async {
        let handoff = NewSessionHandoff()
        handoff.created(sessionID: "created-id")

        handoff.withdrawCreated()

        XCTAssertNil(handoff.consumeCreated())
    }
}
