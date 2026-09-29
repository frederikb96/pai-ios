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
/// assertion is exact rather than inferred from a delay. Holds every waiter, so a test proving a
/// race can park two callers on one gate and have both resume — a single-slot version drops the
/// earlier waiter and hangs it forever instead.
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

    /// The server's own version counter per key — bumped on every accepted write (`putDraft` or
    /// `deleteDraft` alike), exactly like the real backend.
    private var _serverVersion: [String: Int] = [:]
    var serverVersion: [String: Int] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _serverVersion
        }
        set {
            lock.lock()
            _serverVersion = newValue
            lock.unlock()
        }
    }
    private var _lastDeviceId: [String: String?] = [:]
    var lastDeviceId: [String: String?] {
        lock.lock()
        defer { lock.unlock() }
        return _lastDeviceId
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
        key: String, text: String, deviceId: String?, sessionType: String?, workingDir: String?, model: String?,
        thinking: String?
    ) async throws -> DraftWriteResult {
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
        let newVersion = bumpServerVersion(key: key, deviceId: deviceId)
        return DraftWriteResult(key: key, version: newVersion)
    }

    func deleteDraft(key: String) async throws -> DraftWriteResult {
        record("deleteDraft:start:\(key)")
        if let deleteGate {
            await deleteGate.wait()
        }
        record("deleteDraft:done:\(key)")
        let newVersion = bumpServerVersion(key: key, deviceId: nil)
        return DraftWriteResult(key: key, version: newVersion)
    }

    /// Plain, non-`async` on purpose — `NSLock.lock()`/`unlock()` are unavailable to call directly
    /// from an `async` context, matching `record(_:)`'s own identical shape just below.
    private func bumpServerVersion(key: String, deviceId: String?) -> Int {
        lock.lock()
        defer { lock.unlock() }
        if let deviceId {
            _lastDeviceId[key] = deviceId
        }
        let newVersion = (_serverVersion[key] ?? 0) + 1
        _serverVersion[key] = newVersion
        return newVersion
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

        await waitUntil { store.draft(for: "s1").knownVersion != nil }
        XCTAssertEqual(store.draft(for: "s1").knownVersion, 1)
        XCTAssertEqual(fake.lastDeviceId["s1"] ?? nil, store.deviceId, "the write must carry this device's own id")
    }

    /// The whole fix, in one test: a slow write followed by three further edits must produce
    /// exactly one further write once the slow one settles — never one write per edit. The
    /// previous shape awaited the in-flight write and then started its own, fanning every debounce
    /// that expired while a slow write was on the wire out into its own PUT.
    func testASlowWriteFollowedByThreeEditsProducesExactlyOneFurtherWrite() async {
        let fake = FakeDraftsFetching()
        let gate = Gate()
        fake.putGate = gate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "one")
        await waitUntil { fake.callLog.contains("putDraft:start:s1") }

        // Three further edits while the first write is still gated shut on the wire — each would
        // have fired its own debounce-driven flush under the old "await, then send" shape.
        store.setDraftText(key: "s1", text: "one two")
        store.setDraftText(key: "s1", text: "one two three")
        store.setDraftText(key: "s1", text: "one two three four")

        await gate.open()
        await waitUntil { fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count == 2 }
        // Give any further, wrongly-fanned-out write every chance to also have fired.
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(
            fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count, 2,
            "the first write, plus exactly one coalesced follow-up — never one per edit")
        await waitUntil { store.draft(for: "s1").knownVersion == 2 }
        XCTAssertEqual(
            store.draft(for: "s1").text, "one two three four",
            "the coalesced write must carry whatever text is current when it actually fires")
    }

    /// Five keystrokes in quick succession, with nothing in flight yet, must produce exactly one
    /// write — each edit restarts the debounce rather than queuing its own flush.
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

    // MARK: - Retry after a failed flush

    /// A failed flush must not sit unretried until the next edit — the whole point of a retry
    /// with backoff is reaching the server again on its own, for a draft nothing else touches for
    /// a while.
    func testAFailedFlushRetriesOnItsOwnAndEventuallySucceeds() async {
        let fake = FakeDraftsFetching()
        fake.putFailuresRemaining = 2
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "hello")

        await waitUntil(timeout: 5) { store.draft(for: "s1").knownVersion != nil }
        XCTAssertEqual(store.draft(for: "s1").knownVersion, 1)
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

        await waitUntil(timeout: 5) { store.draft(for: "s1").knownVersion != nil }
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

        await waitUntil(timeout: 5) { store.draft(for: "s1").knownVersion != nil }
        XCTAssertEqual(store.draft(for: "s1").text, "hello world")
        XCTAssertFalse(
            scheduler.durations.contains(DraftStore.retryBaseSeconds * 2), "the backoff must not have carried over")
    }

    /// A write that failed and is waiting to retry is exactly as unfinished as one that has not
    /// been attempted yet — adopting an older server row in the gap would silently discard it.
    func testSyncNeverOverwritesAKeyWhoseWriteFailedAndIsWaitingToRetry() async {
        let fake = FakeDraftsFetching()
        fake.putFailuresRemaining = 1
        fake.serverVersion["s1"] = 4
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "stale server copy", sessionType: nil, workingDir: nil, updatedAt: nil, version: 4)
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
    /// clear's own delete is still on the wire — must be queued behind that delete, not race it:
    /// the delete is by key, not by the row it was meant to remove, so it would otherwise remove
    /// whatever the server currently holds — including a newer write that reached it first.
    func testANewEditAfterClearDraftIsQueuedBehindTheStillInFlightDelete() async {
        let fake = FakeDraftsFetching()
        let deleteGate = Gate()
        fake.deleteGate = deleteGate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        store.setDraftText(key: "s1", text: "first message")
        await waitUntil { fake.callLog.contains("putDraft:done:s1") }

        store.clearDraft(key: "s1")
        // The delete has reached the server but is held there — exactly the window a slow or
        // congested connection opens wide.
        await waitUntil { fake.callLog.contains("deleteDraft:start:s1") }

        store.setDraftText(key: "s1", text: "new dictation")
        XCTAssertEqual(
            store.draft(for: "s1").text, "new dictation", "the local copy must never wait on any network round trip")

        // The new edit's own write must not reach the server while the delete is still on the
        // wire — give it every chance to (wrongly) race ahead before proving it did not.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            fake.callLog.filter { $0.hasPrefix("putDraft:start") }.count, 1,
            "the new edit's write reached the server before the delete did")

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
            ], "the new edit's write must land strictly after the delete, never before it")

        // The delete bumped the version; the queued write bumped it again — the server ends up
        // with the newer text at a version strictly ahead of the delete's own.
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "new dictation", sessionType: nil, workingDir: nil, updatedAt: nil,
                version: fake.serverVersion["s1"] ?? 0)
        ]
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "new dictation")
    }

    // MARK: - syncFromServer

    func testSyncAdoptsARowWithNoLocalClaimOnIt() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s2", text: "from another device", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)
        ]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s2").text, "from another device")
        XCTAssertEqual(store.draft(for: "s2").knownVersion, 1)
    }

    /// The core fix this rewrite exists for: a row whose `version` is not strictly greater than
    /// what this device already recorded is ignored — **even when its text differs** — however
    /// that response is ordered against a write this device already sent. This is what makes a
    /// poll that predates a flush, but is delivered after that flush's own response, harmless.
    func testARowWhoseVersionIsNotStrictlyGreaterIsIgnoredEvenWhenItsTextDiffers() async {
        let fake = FakeDraftsFetching()
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        store.setDraftText(key: "s1", text: "one two three")
        await waitUntil { store.draft(for: "s1").knownVersion == 1 }

        // A response that predates this device's own flush — same version this device already
        // has, but carrying the OLDER text the flush just replaced.
        fake.remoteDrafts = [
            Draft(key: "s1", text: "one two", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)
        ]
        await store.syncFromServer()

        XCTAssertEqual(
            store.draft(for: "s1").text, "one two three",
            "a row at a version no newer than what this device already has must never win, whatever its content")
    }

    /// A key with an unwritten local edit is strictly newer than anything a poll can report —
    /// syncing while a debounce is still pending must not overwrite it.
    func testSyncNeverOverwritesAKeyWithAnUnwrittenLocalEdit() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s1", text: "stale server copy", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)
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
            Draft(key: "s1", text: "older text", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)
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
            Draft(key: "s1", text: "sent message", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)
        ]
        let getGate = Gate()
        fake.getGate = getGate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        let sync = Task { await store.syncFromServer() }
        await waitUntil { fake.callLog.contains("getDrafts") }
        store.setDraftText(key: "s1", text: "")
        store.setDraftText(key: "s1", text: "next message")
        await waitUntil { fake.callLog.contains("putDraft:done:s1") }
        await waitUntil { store.draft(for: "s1").text == "next message" && store.draft(for: "s1").knownVersion != nil }
        await getGate.open()
        await sync.value

        XCTAssertEqual(store.draft(for: "s1").text, "next message")
    }

    /// A key this device has never reconciled with the server at all is treated as `knownVersion
    /// == -1` — any real row, including one at `version == 0`, is strictly newer and is adopted.
    func testAFreshServerRowAtVersionZeroIsAdoptedByAKeyWithNoKnownVersionYet() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(key: "s1", text: "brand new", sessionType: nil, workingDir: nil, updatedAt: nil, version: 0)
        ]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())

        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "brand new")
        XCTAssertEqual(store.draft(for: "s1").knownVersion, 0)
    }

    /// A key absent from the response is never touched — the row is never actually deleted
    /// server-side (a discard writes empty text, it never removes the row), so nothing may ever
    /// read "not listed" as "gone, drop the local copy".
    func testSyncNeverTouchesAKeyTheResponseSimplyDoesNotList() async {
        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [Draft(key: "s1", text: "seed", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        await store.syncFromServer()
        XCTAssertEqual(store.draft(for: "s1").text, "seed")

        fake.remoteDrafts = []
        await store.syncFromServer()

        XCTAssertEqual(
            store.draft(for: "s1").text, "seed", "a response that stopped listing this key must not delete it locally")
    }

    /// A local draft that has never been reconciled with the server at all (no `knownVersion` yet
    /// — an edit still waiting on its first successful flush) must survive a poll that simply
    /// does not mention it yet, or a slow first write would lose the draft entirely.
    func testSyncLeavesAnUnreconciledLocalKeyAloneEvenWhenTheServerHasNeverHeardOfIt() async {
        let fake = FakeDraftsFetching()
        // A scheduler that never fires keeps this edit unreconciled (no knownVersion) for the
        // whole test, without also triggering the "pending edit" skip this test is not about.
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        store.drafts["s1"] = DraftEntry(text: "never yet flushed", sessionType: nil, workingDir: nil)

        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "never yet flushed")
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

    /// The device id is minted once and persisted — a relaunch must send the SAME id, not a fresh
    /// one every time the app starts, or "recording on <device>" would name a different device on
    /// every cold start.
    func testTheDeviceIdSurvivesARelaunch() async {
        let storage = SettingsInMemoryKeyValueStore()
        let firstLaunch = DraftStore(api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)
        let secondLaunch = DraftStore(
            api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)

        XCTAssertEqual(firstLaunch.deviceId, secondLaunch.deviceId)
    }

    /// Restoring is never itself a claim: a stale restored draft must never win against a fresher
    /// row already on the server by the time the app reopens — the very next sync has to adopt
    /// the server's copy, exactly as it would for any other key with no local claim.
    func testARestoredDraftNeverOverwritesAFresherRowAlreadyOnTheServer() async {
        let storage = SettingsInMemoryKeyValueStore()
        let beforeClosing = DraftStore(
            api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)
        beforeClosing.drafts["s1"] = DraftEntry(
            text: "stale, from before closing", sessionType: nil, workingDir: nil, knownVersion: 1)

        let fake = FakeDraftsFetching()
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "sent from another device meanwhile", sessionType: nil, workingDir: nil,
                updatedAt: nil, version: 2)
        ]
        let afterRelaunch = DraftStore(api: fake, scheduler: InstantDraftScheduler(), localPersistence: storage)
        XCTAssertEqual(
            afterRelaunch.draft(for: "s1").text, "stale, from before closing",
            "restoring must populate `drafts` alone — no claim that would make the store hold onto this")

        await afterRelaunch.syncFromServer()

        XCTAssertEqual(afterRelaunch.draft(for: "s1").text, "sent from another device meanwhile")
    }

    /// Restoring must equally never make a key immune to a response simply not listing it any
    /// more than an ordinary local key would be — nothing here deletes on absence either.
    func testARestoredDraftIsUntouchedByAResponseThatDoesNotListIt() async {
        let storage = SettingsInMemoryKeyValueStore()
        let beforeClosing = DraftStore(
            api: FakeDraftsFetching(), scheduler: InstantDraftScheduler(), localPersistence: storage)
        beforeClosing.drafts["s1"] = DraftEntry(
            text: "already sent before the relaunch", sessionType: nil, workingDir: nil, knownVersion: 1)

        let fake = FakeDraftsFetching()
        fake.remoteDrafts = []
        let afterRelaunch = DraftStore(api: fake, scheduler: InstantDraftScheduler(), localPersistence: storage)

        await afterRelaunch.syncFromServer()

        XCTAssertEqual(afterRelaunch.draft(for: "s1").text, "already sent before the relaunch")
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
    /// `version` has not moved — attachments live in their own table and are adopted
    /// independently of the text-ordering rule.
    func testSyncAdoptsAnAttachmentAddedByAnotherDeviceEvenWithAnUnchangedVersion() async {
        let fake = FakeDraftsFetching()
        let attachment = DraftAttachment(
            id: "a1", filename: "from-laptop.png", path: "/tmp/from-laptop.png", size: 10,
            contentType: "image/png", state: "stored", createdAt: "t1")
        fake.remoteDrafts = [
            Draft(key: "s1", text: "seed", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1)
        ]
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        await store.syncFromServer()
        XCTAssertEqual(store.draft(for: "s1").attachments, [])

        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "seed", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1,
                attachments: [attachment])
        ]
        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").attachments, [attachment])
    }

    /// The same rule holds while the text side is dirty: another device's attachment must still
    /// show up even though this device's own edit is still unwritten.
    func testSyncAdoptsAnAttachmentEvenWhileTheLocalTextEditIsStillUnwritten() async {
        let fake = FakeDraftsFetching()
        let attachment = DraftAttachment(
            id: "a1", filename: "from-laptop.png", path: "/tmp/from-laptop.png", size: 10,
            contentType: "image/png", state: "stored", createdAt: "t1")
        fake.remoteDrafts = [
            Draft(
                key: "s1", text: "server text", sessionType: nil, workingDir: nil, updatedAt: nil, version: 5,
                attachments: [attachment])
        ]
        let store = DraftStore(api: fake, scheduler: NeverFlushDraftScheduler())
        store.setDraftText(key: "s1", text: "still typing, unflushed")

        await store.syncFromServer()

        XCTAssertEqual(store.draft(for: "s1").text, "still typing, unflushed", "the dirty text must not be replaced")
        XCTAssertEqual(store.draft(for: "s1").attachments, [attachment], "the attachment must still be adopted")
    }

    // MARK: - recordVersionAfterSend

    func testRecordVersionAfterSendUpdatesKnownVersionOnAnUntouchedEmptyEntry() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: NeverFlushDraftScheduler())
        // Seeded directly, bypassing `setDraftText`'s own debounced flush entirely — this test is
        // about the guard `recordVersionAfterSend` itself applies, not about racing a real write.
        store.drafts["s1"] = DraftEntry(text: "", sessionType: nil, workingDir: nil)

        store.recordVersionAfterSend(key: "s1", version: 9)

        XCTAssertEqual(store.draft(for: "s1").knownVersion, 9)
    }

    /// The one hazard this method exists to avoid: a fresh edit typed into the same key before
    /// the send's own response arrived must never be clobbered.
    func testRecordVersionAfterSendDoesNothingIfTheEntryWasEditedAgainInTheMeantime() async {
        let store = DraftStore(api: FakeDraftsFetching(), scheduler: NeverFlushDraftScheduler())
        store.drafts["s1"] = DraftEntry(text: "already typing the next message", sessionType: nil, workingDir: nil)

        store.recordVersionAfterSend(key: "s1", version: 9)

        XCTAssertEqual(store.draft(for: "s1").text, "already typing the next message")
        XCTAssertNil(store.draft(for: "s1").knownVersion, "non-empty text is the signal that this key moved on")
    }

    /// A write or delete genuinely in flight for the key must also block this — the send's own
    /// version would otherwise race whatever that other request is about to record.
    func testRecordVersionAfterSendDoesNothingWhileAWriteIsInFlightForTheKey() async {
        let fake = FakeDraftsFetching()
        let gate = Gate()
        fake.putGate = gate
        let store = DraftStore(api: fake, scheduler: InstantDraftScheduler())
        store.setDraftText(key: "s1", text: "typing")
        await waitUntil { fake.callLog.contains("putDraft:start:s1") }

        store.recordVersionAfterSend(key: "s1", version: 9)

        XCTAssertNotEqual(store.draft(for: "s1").knownVersion, 9)
        await gate.open()
    }
}
