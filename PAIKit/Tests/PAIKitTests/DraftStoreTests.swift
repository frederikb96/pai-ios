import XCTest

@testable import PAIKit

/// A fake clock the test advances by hand.
private final class FakeWallClock: WallClock, @unchecked Sendable {
    var current: Date
    init(_ date: Date = Date(timeIntervalSince1970: 0)) { current = date }
    func now() -> Date { current }
    func advance(by seconds: TimeInterval) { current = current.addingTimeInterval(seconds) }
}

/// Resolves immediately — the debounce window itself is not what these tests are proving.
private struct InstantDraftScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws {}
}

/// Never resolves within a test's lifetime, so a debounce scheduled against it stays "pending"
/// for as long as the test needs — used to prove `syncFromServer` holds off on a key with an
/// unwritten local edit.
private struct NeverFlushDraftScheduler: DraftScheduler {
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
    }
}

/// A rendezvous a test can use to make one call wait for an explicit signal, so an ordering
/// assertion is exact rather than inferred from a delay.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { self.continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private final class FakeDraftsFetching: DraftsFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _callLog: [String] = []
    var callLog: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _callLog
    }

    var remoteDrafts: [Draft] = []
    var putGate: Gate?

    func getDrafts() async throws -> [Draft] {
        record("getDrafts")
        return remoteDrafts
    }

    func putDraft(key: String, text: String, sessionType: String?, workingDir: String?) async throws -> PutDraftResult {
        record("putDraft:start:\(key)")
        if let putGate {
            await putGate.wait()
        }
        record("putDraft:done:\(key)")
        if text.isEmpty && sessionType == nil && workingDir == nil {
            return .deleted(key: key)
        }
        return .saved(
            Draft(key: key, text: text, sessionType: sessionType, workingDir: workingDir, updatedAt: "server-\(text)")
        )
    }

    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        record("deleteDraft:\(key)")
        return PaiDraftDeleteResult(key: key, deleted: true)
    }

    private func record(_ entry: String) {
        lock.lock()
        _callLog.append(entry)
        lock.unlock()
    }
}

@MainActor
final class DraftStoreTests: XCTestCase {

    /// Polls the condition via yields rather than sleeping — see `TranscriptSendTests`.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    // MARK: - Basic reads and edits

    func testDraftForAnUnknownKeyIsEmpty() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        XCTAssertEqual(store.draft(for: "unknown"), .empty)
    }

    func testSettingTextDoesNotClobberAnAlreadyChosenSessionType() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        store.selectSessionType("fast")
        store.setDraftText(key: DraftKey.newSession, text: "hello")

        let entry = store.draft(for: DraftKey.newSession)
        XCTAssertEqual(entry.text, "hello")
        XCTAssertEqual(entry.sessionType, "fast", "an unrelated edit should not have reset the launch choice")
    }

    /// A chosen directory and `sessionType == "custom"` are one decision, not two independent
    /// fields — this is the coupling the report calls out as easy to get subtly wrong.
    func testSelectingAWorkingDirectoryForcesSessionTypeToCustom() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        store.selectWorkingDir("/home/frederik/Programming/pai-ios")
        XCTAssertEqual(store.draft(for: DraftKey.newSession).sessionType, "custom")
    }

    func testClearingTheWorkingDirectoryClearsTheSessionTypeWithIt() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        store.selectWorkingDir("/home/frederik/Programming/pai-ios")
        store.selectWorkingDir(nil)

        let entry = store.draft(for: DraftKey.newSession)
        XCTAssertNil(entry.workingDir)
        XCTAssertNil(entry.sessionType, "clearing the directory should have cleared the derived session type too")
    }

    func testClearDraftRemovesTheLocalEntryImmediately() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        store.setDraftText(key: "s1", text: "typing")
        store.clearDraft(key: "s1")

        XCTAssertEqual(store.draft(for: "s1"), .empty)
    }

    // MARK: - Debounced flush

    func testAnEditFlushesToTheServerAfterTheDebounce() async {
        let fake = FakeDraftsFetching()
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "hello")

        // Poll the condition the assertion itself checks, not an earlier proxy for it: the fake
        // logs "done" from inside `putDraft`, on whatever executor that runs on, which resumes
        // independently of — and racily against — `flush`'s own continuation back on the main
        // actor that actually applies the result to `store.drafts`. Waiting on the log instead
        // of on `remoteUpdatedAt` passed under load (it never failed alone) but flaked once
        // under the full suite.
        await waitUntil { store.draft(for: "s1").remoteUpdatedAt != nil }
        XCTAssertEqual(store.draft(for: "s1").remoteUpdatedAt, "server-hello")
    }

    /// Five keystrokes in quick succession must produce exactly one write, not five — each edit
    /// restarts the debounce rather than queuing its own flush.
    func testRapidEditsProduceExactlyOneFlushNotOnePerEdit() async {
        let fake = FakeDraftsFetching()
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        for text in ["h", "he", "hel", "hell", "hello"] {
            store.setDraftText(key: "s1", text: text)
        }

        await waitUntil { fake.callLog.contains("putDraft:done:s1") }
        // Give any stray second flush a chance to also have fired, if the cancel had not worked.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count, 1)
        XCTAssertEqual(
            store.draft(for: "s1").text, "hello", "the write should carry the latest text, not an early keystroke")
    }

    /// Both `putDraft`'s outcomes must be readable through `remoteUpdatedAt` — a `.deleted`
    /// result (an empty draft) is not an error, and must not be treated as a failed write that
    /// keeps retrying.
    func testAFlushThatComesBackDeletedClearsRemoteUpdatedAtRatherThanRetrying() async {
        let fake = FakeDraftsFetching()
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "will be cleared")
        await waitUntil { fake.callLog.contains("putDraft:done:s1") }
        // Force the next flush to answer `.deleted` by making the entry empty without going
        // through `clearDraft` (which would remove the entry locally too).
        store.setDraftText(key: "s1", text: "")

        await waitUntil { fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count == 2 }
        await waitUntil { store.draft(for: "s1").remoteUpdatedAt == nil }

        XCTAssertNotNil(
            store.draft(for: "s1"), "the local entry survives a .deleted result — see the doc comment on flush")
        XCTAssertNil(store.draft(for: "s1").remoteUpdatedAt)
    }

    // MARK: - clearDraft ordering against an in-flight write

    /// The delete must never overtake a write already in flight for the same key — otherwise the
    /// delete could land first and the write resurrect an entry the user just discarded.
    func testClearDraftWaitsForAnInFlightWriteBeforeDeleting() async {
        let fake = FakeDraftsFetching()
        let gate = Gate()
        fake.putGate = gate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "hello")
        await waitUntil { fake.callLog.contains("putDraft:start:s1") }

        store.clearDraft(key: "s1")
        // The write is still gated shut — nothing should have reached deleteDraft yet.
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(
            fake.callLog.contains { $0.hasPrefix("deleteDraft") }, "delete fired before the in-flight write finished")

        await gate.open()
        await waitUntil { fake.callLog.contains { $0.hasPrefix("deleteDraft") } }

        XCTAssertEqual(fake.callLog, ["putDraft:start:s1", "putDraft:done:s1", "deleteDraft:s1"])
    }

    // MARK: - syncFromServer

    func testSyncAdoptsARowWithNoLocalClaimOnIt() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s2", text: "from another device", sessionType: nil, workingDir: nil, updatedAt: "t1")
        ]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s2").text, "from another device")
    }

    /// A key with an unwritten local edit is strictly newer than anything a poll can report —
    /// syncing while a debounce is still pending must not overwrite it.
    func testSyncNeverOverwritesAKeyWithAnUnwrittenLocalEdit() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s1", text: "stale server copy", sessionType: nil, workingDir: nil, updatedAt: "t1")
        ]
        // A scheduler that never resolves keeps the debounce "pending" for the whole test.
        let store = DraftStore(api: fake, scheduler: NeverFlushDraftScheduler())

        store.setDraftText(key: "s1", text: "still typing")
        await store.syncFromServer()

        XCTAssertEqual(
            store.draft(for: "s1").text, "still typing", "an in-flight local edit was overwritten by a stale poll")
    }

    func testSyncSkipsAKeyWithinTheClearedGraceWindow() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [Draft(key: "s1", text: "resurrected?", sessionType: nil, workingDir: nil, updatedAt: "t1")]
        let clock = FakeWallClock()
        let store = DraftStore(api: fake, clock: clock, scheduler: InstantDraftScheduler())

        store.clearDraft(key: "s1")
        clock.advance(by: DraftStore.clearedGraceSeconds - 0.1)
        await store.syncFromServer()

        XCTAssertEqual(
            store.draft(for: "s1"), .empty, "a poll landing inside the grace window resurrected a just-cleared draft")
    }

    func testSyncAdoptsAgainOnceTheClearedGraceWindowHasPassed() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s1", text: "a fresh edit from elsewhere", sessionType: nil, workingDir: nil, updatedAt: "t1")
        ]
        let clock = FakeWallClock()
        let store = DraftStore(api: fake, clock: clock, scheduler: InstantDraftScheduler())

        store.clearDraft(key: "s1")
        clock.advance(by: DraftStore.clearedGraceSeconds + 0.1)
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "a fresh edit from elsewhere")
    }

    /// `clearedAt` is the one unbounded map in this store — a discarded key's marker survived
    /// past its own grace window forever, for the life of the process, unless something prunes
    /// it. `syncFromServer` is the natural periodic hook to do that from.
    func testSyncPrunesAClearedAtMarkerOnceItsGraceWindowHasPassed() async {
        let fake = FakeDraftsFetching()
        let clock = FakeWallClock()
        let store = DraftStore(api: fake, clock: clock, scheduler: InstantDraftScheduler())

        store.clearDraft(key: "s1")
        XCTAssertEqual(store.clearedAt.count, 1)

        clock.advance(by: DraftStore.clearedGraceSeconds + 0.1)
        await store.syncFromServer()

        XCTAssertTrue(
            store.clearedAt.isEmpty, "an expired cleared-key marker must not be held for the process lifetime")
    }

    /// A key this device once reconciled with the server (it carries a `remoteUpdatedAt`) but
    /// that the server no longer lists means another client sent or discarded it — drop it.
    func testSyncDropsALocalKeyOnceReconciledThatTheServerNoLongerLists() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [Draft(key: "s1", text: "seed", sessionType: nil, workingDir: nil, updatedAt: "t1")]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        await store.syncFromServer()
        XCTAssertEqual(store.draft(for: "s1").text, "seed")

        fake.remoteDrafts = []
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1"), .empty)
    }

    /// A local draft that has never been reconciled with the server at all (no `remoteUpdatedAt`
    /// yet — an edit still waiting on its first successful flush) must survive a poll that simply
    /// does not mention it yet, or a slow first write would lose the draft entirely.
    func testSyncLeavesAnUnreconciledLocalKeyAloneEvenWhenTheServerHasNeverHeardOfIt() async {
        let fake = FakeDraftsFetching()
        // A scheduler that never fires keeps this edit unreconciled (no remoteUpdatedAt) for the
        // whole test, without also triggering the "pending edit" skip this test is not about.
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        store.drafts["s1"] = DraftEntry(
            text: "never yet flushed", sessionType: nil, workingDir: nil, remoteUpdatedAt: nil)

        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "never yet flushed")
    }
}
