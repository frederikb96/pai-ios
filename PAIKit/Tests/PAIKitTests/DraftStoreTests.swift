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

/// Resolves instantly on its first call, then never again — the debounce that starts a flush
/// resolves right away, but any retry scheduled after a failure stays pending indefinitely,
/// giving a test a stable window to inspect state mid-retry rather than racing the retry itself.
private final class FlushOnceDraftScheduler: DraftScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0

    private func recordCallAndCheckIfFirst() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount == 1
    }

    func sleep(seconds: TimeInterval) async throws {
        guard recordCallAndCheckIfFirst() else {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
            return
        }
    }
}

/// Resolves immediately like `InstantDraftScheduler`, but records every duration it was asked to
/// sleep for — what a retry-backoff test reads to prove the delay actually grows, without the
/// test itself waiting out real seconds.
private final class RecordingDraftScheduler: DraftScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [TimeInterval] = []
    var durations: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _durations
    }
    private func record(_ seconds: TimeInterval) {
        lock.lock()
        _durations.append(seconds)
        lock.unlock()
    }

    func sleep(seconds: TimeInterval) async throws {
        record(seconds)
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
    var getGate: Gate?
    /// Consecutive `putDraft` calls left to fail before succeeding — what a retry test uses to
    /// prove a failed flush is retried rather than swallowed.
    private var _putFailuresRemaining = 0
    var putFailuresRemaining: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _putFailuresRemaining
        }
        set {
            lock.lock()
            _putFailuresRemaining = newValue
            lock.unlock()
        }
    }

    func getDrafts() async throws -> [Draft] {
        record("getDrafts")
        let snapshot = remoteDrafts
        if let getGate {
            await getGate.wait()
        }
        return snapshot
    }

    private struct SimulatedFailure: Error {}

    func putDraft(
        key: String, text: String, sessionType: String?, workingDir: String?, model: String?, thinking: String?
    ) async throws -> PutDraftResult {
        record("putDraft:start:\(key)")
        if let putGate {
            await putGate.wait()
        }
        record("putDraft:done:\(key)")
        if putFailuresRemaining > 0 {
            putFailuresRemaining -= 1
            record("putDraft:failed:\(key)")
            throw SimulatedFailure()
        }
        if text.isEmpty && sessionType == nil && workingDir == nil && model == nil && thinking == nil {
            return .deleted(key: key)
        }
        return .saved(
            Draft(
                key: key, text: text, sessionType: sessionType, workingDir: workingDir, model: model,
                thinking: thinking, updatedAt: "server-\(text)")
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

    /// `selectModel` is independent of the session-type/working-dir coupling above — picking a
    /// model must not disturb either.
    func testSelectingAModelDoesNotClobberAnAlreadyChosenSessionType() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        store.selectSessionType("fast")
        store.selectModel("opus")

        let entry = store.draft(for: DraftKey.newSession)
        XCTAssertEqual(entry.sessionType, "fast")
        XCTAssertEqual(entry.model, "opus")
    }

    /// The set of thinking levels a model accepts is a property of that model — a level chosen
    /// for the previous one is not necessarily valid for a new choice, so changing the model
    /// clears it rather than risk sending a combination the launch would reject.
    func testChoosingADifferentModelClearsAPreviouslyChosenThinkingLevel() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        store.selectModel("sonnet")
        store.selectThinking("high")
        XCTAssertEqual(store.draft(for: DraftKey.newSession).thinking, "high")

        store.selectModel("opus")

        XCTAssertNil(store.draft(for: DraftKey.newSession).thinking)
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

    // MARK: - Retry after a failed flush

    /// A failed flush must not sit unretried until the next edit — the whole point of a retry
    /// with backoff is reaching the server again on its own, for a draft nothing else touches for
    /// a while.
    func testAFailedFlushRetriesOnItsOwnAndEventuallySucceeds() async {
        let fake = FakeDraftsFetching()
        fake.putFailuresRemaining = 2
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "hello")

        await waitUntil(timeout: 5) { store.draft(for: "s1").remoteUpdatedAt != nil }
        XCTAssertEqual(store.draft(for: "s1").remoteUpdatedAt, "server-hello")
        XCTAssertEqual(
            fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count, 3,
            "two failures, then the retry that succeeds"
        )
    }

    /// The wait between retries doubles with each consecutive failure rather than retrying at a
    /// fixed interval — proved against the scheduler's own recorded durations, never by waiting
    /// out real seconds.
    func testARetrysWaitDoublesWithEachConsecutiveFailure() async {
        let fake = FakeDraftsFetching()
        fake.putFailuresRemaining = 3
        let scheduler = RecordingDraftScheduler()
        let store = DraftStore(api: fake, scheduler: scheduler)

        store.setDraftText(key: "s1", text: "hello")

        await waitUntil(timeout: 5) { store.draft(for: "s1").remoteUpdatedAt != nil }
        // The first duration is the ordinary debounce; the next three are the retry backoff.
        let retryDurations = Array(scheduler.durations.dropFirst())
        XCTAssertEqual(
            retryDurations,
            [DraftStore.retryBaseSeconds, DraftStore.retryBaseSeconds * 2, DraftStore.retryBaseSeconds * 4])
    }

    /// A key that failed once and is typed into again must not inherit the old attempt count's
    /// longer wait — a fresh edit is a fresh debounce, not a doubled retry.
    func testAFreshEditResetsTheRetryBackoff() async {
        let fake = FakeDraftsFetching()
        fake.putFailuresRemaining = 1
        let scheduler = RecordingDraftScheduler()
        let store = DraftStore(api: fake, scheduler: scheduler)

        store.setDraftText(key: "s1", text: "hello")
        await waitUntil(timeout: 5) { fake.callLog.contains("putDraft:failed:s1") }
        store.setDraftText(key: "s1", text: "hello world")

        await waitUntil(timeout: 5) { store.draft(for: "s1").remoteUpdatedAt != nil }
        XCTAssertEqual(store.draft(for: "s1").text, "hello world")
        XCTAssertFalse(
            scheduler.durations.contains(DraftStore.retryBaseSeconds * 2), "the backoff must not have carried over")
    }

    /// A write that failed and is waiting to retry is exactly as unfinished as one that has not
    /// been attempted yet — adopting an older server row in the gap would silently discard it.
    func testSyncNeverOverwritesAKeyWhoseWriteFailedAndIsWaitingToRetry() async {
        let fake = FakeDraftsFetching()
        fake.putFailuresRemaining = 1
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "stale server copy", sessionType: nil, workingDir: nil, model: nil, thinking: nil,
                updatedAt: "server-old")
        ]
        let store = DraftStore(api: fake, scheduler: FlushOnceDraftScheduler())

        store.setDraftText(key: "s1", text: "local edit")
        await waitUntil(timeout: 5) { fake.callLog.contains("putDraft:failed:s1") }

        await store.syncFromServer()

        XCTAssertEqual(
            store.draft(for: "s1").text, "local edit",
            "the failed write must not have been overwritten by the older row it failed to replace")
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

    /// A poll landing while the debounced write is on the wire must not put back the text the
    /// write is replacing — live dictation writes the draft many times a second, so this window
    /// is open most of the time.
    func testSyncNeverOverwritesAKeyWhoseWriteIsStillInFlight() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s1", text: "older text", sessionType: nil, workingDir: nil, updatedAt: "server-older text")
        ]
        let gate = Gate()
        fake.putGate = gate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "older text and newer words")
        await waitUntil { fake.callLog.contains("putDraft:start:s1") }
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "older text and newer words")
        await gate.open()
    }

    /// A poll whose request left before a local change answers with the copy that change
    /// replaced, even when the change's own write has finished by the time the answer arrives.
    func testSyncIgnoresARowFetchedBeforeALaterLocalEdit() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s1", text: "sent message", sessionType: nil, workingDir: nil, updatedAt: "t-old")
        ]
        let getGate = Gate()
        fake.getGate = getGate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        let sync = Task { await store.syncFromServer() }
        await waitUntil { fake.callLog.contains("getDrafts") }
        store.setDraftText(key: "s1", text: "")
        store.setDraftText(key: "s1", text: "next message")
        await waitUntil { fake.callLog.contains("putDraft:done:s1") }
        await waitUntil { store.draft(for: "s1").remoteUpdatedAt == "server-next message" }
        await getGate.open()
        await sync.value

        XCTAssertEqual(store.draft(for: "s1").text, "next message")
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
