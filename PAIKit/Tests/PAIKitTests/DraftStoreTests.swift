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
/// Holds every waiter, so a test proving a race can park two callers on one gate and have both
/// resume — a single-slot version drops the earlier waiter and hangs it forever instead.
private actor Gate {
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
    var deleteGate: Gate?
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

    /// The server's own version stamp per key — what makes this fake able to enforce
    /// `baseUpdatedAt` the way the real backend does, rather than accepting every write. A fake
    /// that accepts every write cannot express a client racing itself, or another device having
    /// already moved a row out from under this one.
    private var _serverUpdatedAt: [String: String?] = [:]
    var serverUpdatedAt: [String: String?] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _serverUpdatedAt
        }
        set {
            lock.lock()
            _serverUpdatedAt = newValue
            lock.unlock()
        }
    }
    /// Off by default so every test above, none of which pass `baseUpdatedAt`, keeps working
    /// unmodified — only a test that means to exercise the conflict path turns this on.
    var enforcesVersionCheck = false

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
        key: String, text: String, sessionType: String?, workingDir: String?, model: String?, thinking: String?,
        baseUpdatedAt: String?
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
        // Mirrors `repository.upsert_draft`: a `nil` base skips the check entirely (an
        // unconditional write, exactly like a brand new draft this device has never reconciled),
        // and a non-`nil` base that disagrees with what the server actually holds is a conflict.
        if enforcesVersionCheck, let baseUpdatedAt, serverUpdatedAt[key, default: nil] != baseUpdatedAt {
            record("putDraft:conflict:\(key)")
            guard let currentVersion = serverUpdatedAt[key, default: nil] else {
                return .conflict(Draft(key: key, text: "", sessionType: nil, workingDir: nil, updatedAt: nil))
            }
            return .conflict(
                Draft(
                    key: key, text: "server text for \(key)", sessionType: nil, workingDir: nil,
                    updatedAt: currentVersion))
        }
        if text.isEmpty && sessionType == nil && workingDir == nil && model == nil && thinking == nil {
            serverUpdatedAt[key] = .some(nil)
            return .deleted(key: key)
        }
        let newVersion = "server-\(text)"
        serverUpdatedAt[key] = newVersion
        return .saved(
            Draft(
                key: key, text: text, sessionType: sessionType, workingDir: workingDir, model: model,
                thinking: thinking, updatedAt: newVersion)
        )
    }

    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        record("deleteDraft:start:\(key)")
        if let deleteGate {
            await deleteGate.wait()
        }
        record("deleteDraft:done:\(key)")
        return PaiDraftDeleteResult(key: key, deleted: true)
    }

    func flattenDraft(key: String, takeIds: [String], baseUpdatedAt: String?) async throws -> PutDraftResult {
        record("flattenDraft:\(key)")
        return .saved(Draft(key: key, text: "", sessionType: nil, workingDir: nil, updatedAt: "server-flattened"))
    }

    /// Consecutive `addDraftAttachment` calls left to fail before succeeding — mirrors
    /// `putFailuresRemaining`'s shape, for the test proving a failed upload reports `nil` rather
    /// than throwing out of `DraftStore.addAttachment`.
    private var _addAttachmentFailuresRemaining = 0
    var addAttachmentFailuresRemaining: Int {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _addAttachmentFailuresRemaining
        }
        set {
            lock.lock()
            _addAttachmentFailuresRemaining = newValue
            lock.unlock()
        }
    }

    func addDraftAttachment(key: String, file: PaiFileUpload) async throws -> DraftAttachment {
        record("addDraftAttachment:\(key):\(file.filename)")
        if addAttachmentFailuresRemaining > 0 {
            addAttachmentFailuresRemaining -= 1
            throw SimulatedFailure()
        }
        return DraftAttachment(
            id: "attachment-\(file.filename)", filename: file.filename, path: "/tmp/\(file.filename)",
            size: file.data.count, contentType: file.mimeType, state: "stored", createdAt: "t1")
    }

    func removeDraftAttachment(key: String, attachmentId: String) async throws {
        record("removeDraftAttachment:\(key):\(attachmentId)")
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

        XCTAssertEqual(
            fake.callLog, ["putDraft:start:s1", "putDraft:done:s1", "deleteDraft:start:s1", "deleteDraft:done:s1"])
    }

    /// A write started *after* the clear — the next take dictating into the same key while the
    /// clear's own delete is still on the wire — has no ordering against that delete at all: only
    /// a write already in flight *before* the clear is protected (the test above). A delete is by
    /// key, not by the row it was meant to remove, so it deletes *whatever the server currently
    /// holds* — including the newer write — leaving the server with nothing for this key even
    /// though the client's own copy has moved on. The next `syncFromServer` then reads "reconciled
    /// once, gone now" and wipes the local copy too, destroying dictation nobody asked to discard.
    func testANewEditAfterClearDraftSurvivesTheStaleDelete() async {
        let fake = FakeDraftsFetching()
        let deleteGate = Gate()
        fake.deleteGate = deleteGate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "first message")
        await waitUntil { fake.callLog.contains("putDraft:done:s1") }

        store.clearDraft(key: "s1")
        // The delete has reached the server but is held there — exactly the window a slow or
        // congested connection opens wide, and the log shows every take in the reported bug
        // reconnecting for several seconds.
        await waitUntil { fake.callLog.contains("deleteDraft:start:s1") }

        store.setDraftText(key: "s1", text: "new dictation")
        XCTAssertEqual(
            store.draft(for: "s1").text, "new dictation", "the local copy must never wait on any network round trip")

        // The new edit's own write must not reach the server while the stale delete is still on
        // the wire — give it every chance to (wrongly) race ahead before proving it did not.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count, 1,
            "the new edit's write reached the server before the stale delete did")

        await deleteGate.open()
        await waitUntil {
            fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count == 2
                && fake.callLog.filter { $0.hasPrefix("putDraft:done") }.count == 2
        }

        XCTAssertEqual(
            fake.callLog,
            [
                "putDraft:start:s1", "putDraft:done:s1", "deleteDraft:start:s1", "deleteDraft:done:s1",
                "putDraft:start:s1", "putDraft:done:s1",
            ], "the new edit's write must not have reached the server before the stale delete did")

        // The delete removed the key by name, not by the row it was meant to remove — without the
        // ordering above, the server would end up with nothing for "s1" even though the newer
        // write landed, and the next poll would read that as "reconciled once, gone now" and wipe
        // the local copy too.
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "new dictation", sessionType: nil, workingDir: nil,
                updatedAt: "server-new dictation")
        ]
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "new dictation")
    }

    /// A poll landing while a delete is still on the wire, and a write is parked behind it, is
    /// the one moment a key looks to a sync like a draft nobody is writing: the debounce has
    /// already fired, so nothing is pending, and the write has not started, so nothing is in
    /// flight. Adopting the server's pre-delete row there puts the old message back on screen and
    /// then writes it out again over the new one.
    func testSyncLeavesAKeyAloneWhileItsDeleteIsStillOnTheWire() async {
        let fake = FakeDraftsFetching()
        let deleteGate = Gate()
        fake.deleteGate = deleteGate
        let clock = FakeWallClock()
        let store = DraftStore(api: fake, clock: clock, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "first message")
        await waitUntil { fake.callLog.contains("putDraft:done:s1") }
        store.clearDraft(key: "s1")
        await waitUntil { fake.callLog.contains("deleteDraft:start:s1") }
        store.setDraftText(key: "s1", text: "new dictation")
        for _ in 0..<20 { await Task.yield() }
        // Past the just-cleared grace window: a delete slower than that is exactly the case the
        // window cannot cover, and it is the one the reported loss happened on.
        clock.advance(by: DraftStore.clearedGraceSeconds + 0.1)

        // The server still answers with the row the held delete has not removed yet.
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "first message", sessionType: nil, workingDir: nil, updatedAt: "server-first message")
        ]
        await store.syncFromServer()

        XCTAssertEqual(
            store.draft(for: "s1").text, "new dictation", "a racing delete makes the server's row no evidence")

        await deleteGate.open()
        await waitUntil { fake.callLog.filter { $0.hasPrefix("putDraft:done") }.count == 2 }
        XCTAssertEqual(store.draft(for: "s1").text, "new dictation")
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
        // The delete has actually landed: while one is still on the wire the server's row for
        // that key says nothing, however long the grace window has been over.
        await waitUntil { fake.callLog.contains("deleteDraft:done:s1") }
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

    // MARK: - Versioned writes, serialized against themselves and against a genuine conflict

    /// Two writes for the same key, queued back to back, must never produce a conflict against a
    /// fake that actually enforces the version check — the second write starts building its
    /// request only after the first has an answer, so it always carries the freshest base.
    func testTwoWritesQueuedBackToBackAgainstAVersionEnforcingFakeProduceNoConflict() async {
        let fake = FakeDraftsFetching()
        fake.enforcesVersionCheck = true
        let gate = Gate()
        fake.putGate = gate
        // A scheduler that never fires the debounce: both writes below are driven by the explicit
        // `flush(key:)` calls the composer itself makes, not by `setDraftText`'s own debounce.
        let store = DraftStore(api: fake, scheduler: NeverFlushDraftScheduler())

        store.setDraftText(key: "s1", text: "first")
        let firstFlush = Task { await store.flush(key: "s1") }
        await waitUntil { fake.callLog.contains("putDraft:start:s1") }

        // The second edit happens while the first write is still gated shut on the wire.
        var entry = store.draft(for: "s1")
        entry.text = "first and more"
        store.drafts["s1"] = entry
        let secondFlush = Task { await store.flush(key: "s1") }
        // Give the second flush every chance to (wrongly) race ahead before the gate opens.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count, 1,
            "the second flush must wait for the first before even building its own request")

        await gate.open()
        await firstFlush.value
        await secondFlush.value

        XCTAssertFalse(fake.callLog.contains { $0.hasPrefix("putDraft:conflict") })
        XCTAssertEqual(store.draft(for: "s1").text, "first and more")
        XCTAssertEqual(store.draft(for: "s1").remoteUpdatedAt, "server-first and more")
    }

    /// A genuinely stale write — this device's own base having fallen behind because another
    /// device wrote the same key in between — must never let the conflict response's row replace
    /// what is on screen. Only the version stamp may move; the retry that follows, once it fires
    /// with the fresh base, is what actually lands this device's own text.
    func testAConflictingWriteNeverOverwritesOnScreenTextAndTheRetryThenWins() async {
        let fake = FakeDraftsFetching()
        fake.enforcesVersionCheck = true
        // Nothing here relies on the debounce or on `scheduleRetry`'s own timer firing — every
        // flush below is driven explicitly, so a scheduler that never resolves keeps both inert
        // and lets the test control exactly when each write happens.
        let store = DraftStore(api: fake, scheduler: NeverFlushDraftScheduler())

        store.setDraftText(key: "s1", text: "hello")
        await store.flush(key: "s1")
        XCTAssertEqual(store.draft(for: "s1").remoteUpdatedAt, "server-hello")

        // Another device writes the same key without this one knowing.
        fake.serverUpdatedAt["s1"] = "server-otherdevice"

        // This device edits again, still carrying the base it last saw — now stale.
        var entry = store.draft(for: "s1")
        entry.text = "hello world"
        store.drafts["s1"] = entry
        await store.flush(key: "s1")

        XCTAssertTrue(fake.callLog.contains("putDraft:conflict:s1"))
        XCTAssertEqual(
            store.draft(for: "s1").text, "hello world",
            "a conflict response must never have replaced the text on screen")
        XCTAssertEqual(
            store.draft(for: "s1").remoteUpdatedAt, "server-otherdevice",
            "only the version stamp may move on a conflict")

        // The retry, driven explicitly here rather than by `scheduleRetry`'s own timer, now
        // carries the fresh base and must actually win.
        await store.flush(key: "s1")

        XCTAssertEqual(store.draft(for: "s1").text, "hello world")
        XCTAssertEqual(store.draft(for: "s1").remoteUpdatedAt, "server-hello world")
    }

    /// A conflict whose row carries `updated_at: null` means the draft is gone from the server
    /// entirely — another device already sent or discarded it. Retrying would resurrect text
    /// nobody is waiting on, so the local copy is dropped instead of rewritten back onto a row
    /// that no longer exists.
    func testAConflictWhereTheDraftIsGoneElsewhereDropsTheLocalCopyRatherThanResurrectingIt() async {
        let fake = FakeDraftsFetching()
        fake.enforcesVersionCheck = true
        let store = DraftStore(api: fake, scheduler: NeverFlushDraftScheduler())

        store.setDraftText(key: "s1", text: "hello")
        await store.flush(key: "s1")
        XCTAssertEqual(store.draft(for: "s1").remoteUpdatedAt, "server-hello")

        // Another device sent the message (or discarded the draft) — the row is gone.
        fake.serverUpdatedAt["s1"] = .some(nil)

        var entry = store.draft(for: "s1")
        entry.text = "hello world"
        store.drafts["s1"] = entry
        await store.flush(key: "s1")

        XCTAssertTrue(fake.callLog.contains("putDraft:conflict:s1"))
        XCTAssertEqual(
            store.draft(for: "s1"), .empty,
            "a conflict over a row that is gone elsewhere must drop the local copy, not resurrect it")
    }

    // MARK: - Surviving a relaunch

    /// A draft typed and never sent is still there after the app is relaunched — the one place a
    /// version of Freddy's text would otherwise exist nowhere but in memory.
    func testADraftSurvivesBeingConstructedAgainstTheSamePersistedStorage() async {
        let storage = SettingsInMemoryKeyValueStore()
        let fake = FakeDraftsFetching()
        let firstLaunch = DraftStore(api: fake, scheduler: InstantDraftScheduler(), localPersistence: storage)
        firstLaunch.setDraftText(key: "s1", text: "typed before closing the app")

        let secondLaunch = DraftStore(
            api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)

        XCTAssertEqual(secondLaunch.draft(for: "s1").text, "typed before closing the app")
    }

    /// Restoring is never itself a claim: a stale restored draft must never win against a fresher
    /// row already on the server by the time the app reopens — the very next sync has to adopt
    /// the server's copy, exactly as it would for any other key with no local claim.
    func testARestoredDraftNeverOverwritesAFresherRowAlreadyOnTheServer() async {
        let storage = SettingsInMemoryKeyValueStore()
        let beforeClosing = DraftStore(
            api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)
        beforeClosing.drafts["s1"] = DraftEntry(
            text: "stale, from before closing", sessionType: nil, workingDir: nil, remoteUpdatedAt: "t-old")

        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "sent from another device meanwhile", sessionType: nil, workingDir: nil,
                updatedAt: "t-new")
        ]
        let afterRelaunch = DraftStore(api: fake, scheduler: InstantDraftScheduler(), localPersistence: storage)
        XCTAssertEqual(
            afterRelaunch.draft(for: "s1").text, "stale, from before closing",
            "restoring must populate `drafts` alone — no claim that would make the store hold onto this")

        await afterRelaunch.syncFromServer()

        XCTAssertEqual(afterRelaunch.draft(for: "s1").text, "sent from another device meanwhile")
    }

    /// Restoring must equally never itself hold a key the server has since dropped — that is
    /// `syncFromServer`'s job, unchanged, once restoring has made no claim for it to override.
    func testARestoredDraftIsDroppedOnTheFirstSyncIfTheServerNoLongerHasIt() async {
        let storage = SettingsInMemoryKeyValueStore()
        let beforeClosing = DraftStore(
            api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)
        beforeClosing.drafts["s1"] = DraftEntry(
            text: "already sent before the relaunch", sessionType: nil, workingDir: nil, remoteUpdatedAt: "t-old")

        let fake = FakeDraftsFetching()
        fake.remoteDrafts = []
        let afterRelaunch = DraftStore(api: fake, scheduler: InstantDraftScheduler(), localPersistence: storage)

        await afterRelaunch.syncFromServer()

        XCTAssertEqual(afterRelaunch.draft(for: "s1"), .empty)
    }

    // MARK: - Attachments

    func testAddAttachmentAppendsTheUploadedRowAndReturnsIt() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler())
        let file = PaiFileUpload(filename: "photo.jpg", mimeType: "image/jpeg", data: Data("bytes".utf8))

        let uploaded = await store.addAttachment(key: "s1", file: file)

        XCTAssertEqual(uploaded?.filename, "photo.jpg")
        XCTAssertEqual(store.draft(for: "s1").attachments.map(\.filename), ["photo.jpg"])
    }

    /// A failed upload must not silently attach itself anyway — `nil` is the caller's signal to
    /// fall back to sending the bytes inline at message-send time.
    func testAddAttachmentReturnsNilOnFailureAndAddsNothing() async {
        let fake = FakeDraftsFetching()
        fake.addAttachmentFailuresRemaining = 1
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        let file = PaiFileUpload(filename: "photo.jpg", mimeType: "image/jpeg", data: Data("bytes".utf8))

        let uploaded = await store.addAttachment(key: "s1", file: file)

        XCTAssertNil(uploaded)
        XCTAssertEqual(store.draft(for: "s1").attachments, [])
    }

    /// The local copy drops immediately — a caller does not wait on the server round trip to make
    /// the chip disappear.
    func testRemoveAttachmentDropsItLocallyAndTellsTheServer() async {
        let fake = FakeDraftsFetching()
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        let file = PaiFileUpload(filename: "photo.jpg", mimeType: "image/jpeg", data: Data("bytes".utf8))
        guard let uploaded = await store.addAttachment(key: "s1", file: file) else {
            return XCTFail("upload should have succeeded")
        }

        await store.removeAttachment(key: "s1", attachmentId: uploaded.id)

        XCTAssertEqual(store.draft(for: "s1").attachments, [])
        XCTAssertTrue(fake.callLog.contains("removeDraftAttachment:s1:\(uploaded.id)"))
    }

    /// A sync must adopt an attachment another device uploaded even when the draft row's own
    /// `updatedAt` has not moved — the same reasoning `DraftRegion` already needed, since an
    /// attachment lives in its own table too.
    func testSyncAdoptsAnAttachmentAddedByAnotherDeviceEvenWithAnUnchangedUpdatedAt() async {
        let fake = FakeDraftsFetching()
        let attachment = DraftAttachment(
            id: "a1", filename: "from-laptop.png", path: "/tmp/from-laptop.png", size: 10,
            contentType: "image/png", state: "stored", createdAt: "t1")
        fake.remoteDrafts = [
            Draft(key: "s1", text: "seed", sessionType: nil, workingDir: nil, updatedAt: "t1")
        ]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        await store.syncFromServer()
        XCTAssertEqual(store.draft(for: "s1").attachments, [])

        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "seed", sessionType: nil, workingDir: nil, updatedAt: "t1",
                attachments: [attachment])
        ]
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").attachments, [attachment])
    }
}

// MARK: - What a closed dictation take must stop contributing

/// Closing a region folds its words into `text` server-side and leaves the region row standing.
/// A renderer that still counts that region draws the same take twice — the defect behind the
/// composer filling with repeated copies of one sentence. These pin the rule rather than the
/// wording: flip the filter back to "every region" and both go red.
final class DraftEntryDisplayTextTests: XCTestCase {

    private func region(_ takeId: String, _ text: String, _ state: String) -> DraftRegion {
        DraftRegion(takeId: takeId, text: text, state: state, seq: 1, updatedAt: "2026-01-01T00:00:00Z")
    }

    func testAClosedTakeIsNotRenderedAgainBesideTheTextItWasFoldedInto() {
        // Exactly what the server holds the instant a take closes: its words are in `text`, and
        // its region row is still there with the same words in it.
        let entry = DraftEntry(
            text: "hello there", sessionType: nil, workingDir: nil, remoteUpdatedAt: nil,
            regions: [region("t1", "hello there", "final")]
        )

        XCTAssertEqual(entry.displayText, "hello there")
    }

    func testAnOpenTakeStillRendersSoDictationIsVisibleWhileItIsHappening() {
        let entry = DraftEntry(
            text: "typed", sessionType: nil, workingDir: nil, remoteUpdatedAt: nil,
            regions: [region("t1", "spoken", "open")]
        )

        XCTAssertEqual(entry.displayText, "typed \(VoiceRecordingResult.sttPrefix)spoken")
    }

    func testOnlyTheStillOpenTakeOfSeveralContributes() {
        let entry = DraftEntry(
            text: "one two", sessionType: nil, workingDir: nil, remoteUpdatedAt: nil,
            regions: [
                region("t1", "one", "final"),
                region("t2", "two", "final"),
                region("t3", "three", "open"),
            ]
        )

        XCTAssertEqual(entry.displayText, "one two \(VoiceRecordingResult.sttPrefix)three")
    }
}
