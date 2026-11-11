import XCTest

@testable import PAIKit

private actor Rendezvous {
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

/// A drafts API whose poll answers what a test scripts and which remembers the rows removed.
private final class RecordingDraftsApi: DraftsFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [Draft] = []
    private var _removed: [String] = []

    var rows: [Draft] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }
    var removed: [String] { lock.withLock { _removed } }

    func getDrafts() async throws -> [Draft] { rows }
    func putDraft(
        key: String, text: String, deviceId: String?, sessionType: String?, workingDir: String?, model: String?,
        thinking: String?, noMemory: Bool?
    ) async throws -> DraftWriteResult {
        DraftWriteResult(key: key, version: 1, previousText: nil)
    }
    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        PaiDraftDeleteResult(key: key, version: 1, previousText: nil)
    }
    func addDraftAttachment(key: String, file: PaiFileUpload, id: String) async throws -> DraftAttachment {
        throw PaiError.transport("not used")
    }
    func removeDraftAttachment(key: String, attachmentId: String) async throws {
        lock.withLock { _removed.append(attachmentId) }
    }
}

/// A sender whose POSTs a test releases one by one, and whose withdraw answers are scripted — so
/// a request can be "in the air" exactly as long as the scenario needs.
private final class ScriptedApi: OutboxSending, OutboxWithdrawing, @unchecked Sendable {
    private let lock = NSLock()
    private var posts: [String: Rendezvous] = [:]
    private var postAnswers: [String: Result<PostMessageResponse, PaiError>] = [:]
    private var _withdrawCalls: [[String]] = []
    private var _postedIds: [String] = []

    private var failFirstPost: Set<String> = []
    var withdrawAnswer: Result<WithdrawPendingResponse, PaiError> = .failure(.transport("unscripted"))
    var withdrawGate: Rendezvous?

    var withdrawCalls: [[String]] { lock.withLock { _withdrawCalls } }
    var postedIds: [String] { lock.withLock { _postedIds } }

    /// The first POST for this id fails like a timeout (it may have landed); the retry succeeds.
    func failFirstPost(of id: String) { lock.withLock { _ = failFirstPost.insert(id) } }

    /// POSTs for this id wait until ``release(_:answer:)``; any other id answers at once.
    func hold(_ id: String) { lock.withLock { posts[id] = Rendezvous() } }

    func release(_ id: String, answer: Result<PostMessageResponse, PaiError>) async {
        let gate = lock.withLock { () -> Rendezvous? in
            postAnswers[id] = answer
            return posts[id]
        }
        await gate?.open()
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], supersededUploadIds: [String], sessionType: String?, workingDir: String?,
        agent: String?, model: String?,
        thinking: String?, clientMode: String?, heldTake: HeldTake?, noMemory: Bool?
    ) async throws -> PostMessageResponse {
        let (gate, fails) = lock.withLock { () -> (Rendezvous?, Bool) in
            _postedIds.append(clientMessageId)
            return (posts[clientMessageId], failFirstPost.remove(clientMessageId) != nil)
        }
        if fails { throw PaiError.transport("timed out") }
        if let gate {
            await gate.wait()
            let answer = lock.withLock { postAnswers[clientMessageId] }
            return try (answer ?? .failure(.transport("no answer scripted"))).get()
        }
        return PostMessageResponse(sessionId: sessionId ?? "s", messageId: 1)
    }

    func withdrawPending(sessionId: String, clientMessageIds: [String]) async throws -> WithdrawPendingResponse {
        lock.withLock { _withdrawCalls.append(clientMessageIds) }
        if let gate = withdrawGate { await gate.wait() }
        return try withdrawAnswer.get()
    }
}

private func answer(
    withdrawn: [WithdrawnSend] = [], alreadyDelivered: [Int] = [], unresolved: [Int] = [],
    withdrawnClientIds: [String] = [], deliveredClientIds: [String] = []
) -> Result<WithdrawPendingResponse, PaiError> {
    .success(
        WithdrawPendingResponse(
            withdrawn: withdrawn, alreadyDelivered: alreadyDelivered, draftVersion: 2, unresolved: unresolved,
            withdrawnClientIds: withdrawnClientIds, deliveredClientIds: deliveredClientIds))
}

/// Undo send's hard requirement: a message is never BOTH back in the composer and delivered to
/// the model, and is never lost. Each test sits on one way that could break.
@MainActor
final class OutboxUndoSendTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private struct Harness {
        let outbox: OutboxStore
        let drafts: DraftStore
        let api: ScriptedApi
        let draftsApi: RecordingDraftsApi
        let returned: ReturnedFilesLog
    }

    /// What the composer's file staging was handed back.
    @MainActor
    private final class ReturnedFilesLog {
        var batches: [OutboxReturnedFiles] = []
        var names: [String] { batches.flatMap(\.files).map(\.filename) }
    }

    /// The real handover is installed, so what a refused POST does to the composer is the
    /// production closure and not one this file wrote.
    private func makeHarness() -> Harness {
        let api = ScriptedApi()
        let outbox = OutboxStore(api: api, storage: OutboxInMemoryStorage())
        let draftsApi = RecordingDraftsApi()
        let drafts = DraftStore(api: draftsApi)
        let returned = ReturnedFilesLog()
        outbox.installHandover(
            drafts: drafts, sessions: SessionListStore(api: FakeSessionListApi()), handoff: NewSessionHandoff())
        outbox.onFilesReturned = { returned.batches.append($0) }
        return Harness(outbox: outbox, drafts: drafts, api: api, draftsApi: draftsApi, returned: returned)
    }

    private func entry(_ text: String, createdAt: TimeInterval) -> OutboxEntry {
        OutboxEntry(
            target: .session(sessionId: "s1"), text: text, createdAt: Date(timeIntervalSince1970: createdAt))
    }

    /// An entry whose one file travels inline, with the draft upload it stands in for.
    private func entryWithFile(_ text: String, file: String, createdAt: TimeInterval) -> OutboxEntry {
        OutboxEntry(
            target: .session(sessionId: "s1"), text: text,
            inlineFiles: [OutboxInlineFile(localId: "local-\(file)", filename: file, mimeType: "text/plain")],
            supersededUploadIds: ["upload-\(file)"], createdAt: Date(timeIntervalSince1970: createdAt))
    }

    private func fileData(_ file: String) -> [String: Data] { ["local-\(file)": Data(file.utf8)] }

    // MARK: - What leaves, what stays

    func testAnEntryNoRequestWasEverIssuedForComesBackWithoutAskingTheServerAboutIt() async {
        let h = makeHarness()
        let head = entry("head, in the air", createdAt: 1)
        h.api.hold(head.id)
        h.outbox.enqueue(head)
        await waitUntil { h.api.postedIds == [head.id] }
        let behind = entry("queued behind it", createdAt: 2)
        h.outbox.enqueue(behind)
        h.api.withdrawAnswer = answer(withdrawnClientIds: [head.id])

        await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.api.withdrawCalls, [[head.id]], "only what may have left is named")
        XCTAssertFalse(h.outbox.entries.contains { $0.id == behind.id })
        XCTAssertEqual(h.drafts.draft(for: "s1").text, "head, in the air\nqueued behind it")
        XCTAssertFalse(h.api.postedIds.contains(behind.id), "it must never have been posted")
        await h.api.release(head.id, answer: .failure(.transport("cleanup")))
    }

    func testAnInFlightSendComesBackOnlyOnceTheServerSaysItWasWithdrawn() async {
        let h = makeHarness()
        let inTheAir = entry("in the air", createdAt: 1)
        h.api.hold(inTheAir.id)
        h.outbox.enqueue(inTheAir)
        await waitUntil { h.api.postedIds == [inTheAir.id] }
        h.api.withdrawAnswer = answer(withdrawnClientIds: [inTheAir.id])

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "in the air")
        XCTAssertTrue(h.outbox.entries.isEmpty)
        XCTAssertEqual(summary.restored, 1)
        await h.api.release(inTheAir.id, answer: .failure(.transport("cleanup")))
    }

    // MARK: - The late arrival

    func testAPostThatLandsAfterTheWithdrawIsRefusedWithoutPuttingTheTextBackAgain() async {
        let h = makeHarness()
        let inTheAir = entry("in the air", createdAt: 1)
        h.api.hold(inTheAir.id)
        h.outbox.enqueue(inTheAir)
        await waitUntil { h.api.postedIds == [inTheAir.id] }
        h.api.withdrawAnswer = answer(withdrawnClientIds: [inTheAir.id])
        await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        // The server refuses the late request: answered as withdrawn, nothing delivered.
        await h.api.release(
            inTheAir.id,
            answer: .success(
                PostMessageResponse(
                    sessionId: "s1", messageId: 9, duplicate: true, withdrawn: true, textInDraft: false)))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "in the air", "once, not twice")
        XCTAssertTrue(h.outbox.entries.isEmpty)
    }

    func testAPostRefusedBeforeTheWithdrawAnswerArrivesRestoresTheTextOnceNotTwice() async {
        let h = makeHarness()
        let inTheAir = entry("in the air", createdAt: 1)
        h.api.hold(inTheAir.id)
        h.outbox.enqueue(inTheAir)
        await waitUntil { h.api.postedIds == [inTheAir.id] }
        let gate = Rendezvous()
        h.api.withdrawGate = gate
        h.api.withdrawAnswer = answer(withdrawnClientIds: [inTheAir.id])

        let undo = Task { await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts) }
        await waitUntil { !h.api.withdrawCalls.isEmpty }
        await h.api.release(
            inTheAir.id,
            answer: .success(
                PostMessageResponse(
                    sessionId: "s1", messageId: 9, duplicate: true, withdrawn: true, textInDraft: false)))
        await waitUntil { h.outbox.entries.isEmpty }
        await gate.open()
        _ = await undo.value

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "in the air")
    }

    func testARefusalWhoseTextTheServersDraftAlreadyHoldsIsNotPutBack() async {
        let h = makeHarness()
        let sent = entry("withdrawn by another device", createdAt: 1)
        h.api.hold(sent.id)
        h.outbox.enqueue(sent)
        await waitUntil { h.api.postedIds == [sent.id] }

        await h.api.release(
            sent.id,
            answer: .success(
                PostMessageResponse(
                    sessionId: "s1", messageId: 9, duplicate: true, withdrawn: true, textInDraft: true)))
        await waitUntil { h.outbox.entries.isEmpty }

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "")
    }

    // MARK: - What the server says decides

    func testASendTheServerSaysWasDeliveredIsDroppedAndNeverPutBack() async {
        let h = makeHarness()
        let sent = entry("already went", createdAt: 1)
        h.api.hold(sent.id)
        h.outbox.enqueue(sent)
        await waitUntil { h.api.postedIds == [sent.id] }
        h.api.withdrawAnswer = answer(alreadyDelivered: [5], deliveredClientIds: [sent.id])

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "")
        XCTAssertTrue(h.outbox.entries.isEmpty)
        XCTAssertEqual(summary.toast(announceNothing: false), "Already delivered")
        await h.api.release(sent.id, answer: .failure(.transport("cleanup")))
    }

    func testARowTheServerWithdrewCarriesItsOwnTextSoItsEntryIsNotRestoredAsWell() async {
        let h = makeHarness()
        let sent = entry("raced", createdAt: 1)
        h.api.hold(sent.id)
        h.outbox.enqueue(sent)
        await waitUntil { h.api.postedIds == [sent.id] }
        h.api.withdrawAnswer = answer(
            withdrawn: [WithdrawnSend(id: 42, text: "raced", clientMessageId: sent.id)],
            withdrawnClientIds: [sent.id])

        await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "raced")
        await h.api.release(sent.id, answer: .failure(.transport("cleanup")))
    }

    func testWhenTheWithdrawRequestFailsNothingThatMayBeOnTheServerIsTouched() async {
        let h = makeHarness()
        let maybe = entry("maybe delivered", createdAt: 1)
        h.api.hold(maybe.id)
        h.outbox.enqueue(maybe)
        await waitUntil { h.api.postedIds == [maybe.id] }
        h.api.withdrawAnswer = .failure(.transport("offline"))

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.outbox.entries.map(\.id), [maybe.id], "still owed its delivery or its undo")
        XCTAssertEqual(h.drafts.draft(for: "s1").text, "")
        XCTAssertTrue(summary.requestFailed)
        XCTAssertNotNil(summary.toast(announceNothing: false))
        await h.api.release(maybe.id, answer: .failure(.transport("cleanup")))
    }

    func testEntriesNoRequestWasIssuedForStillComeBackWhenTheWithdrawRequestFails() async {
        let h = makeHarness()
        let head = entry("head", createdAt: 1)
        h.api.hold(head.id)
        h.outbox.enqueue(head)
        await waitUntil { h.api.postedIds == [head.id] }
        h.outbox.enqueue(entry("never left", createdAt: 2))
        h.api.withdrawAnswer = .failure(.transport("offline"))

        await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.drafts.draft(for: "s1").text, "never left")
        await h.api.release(head.id, answer: .failure(.transport("cleanup")))
    }

    func testNoFurtherRequestIsIssuedForAnEntryWhileItsWithdrawalIsBeingDecided() async {
        let h = makeHarness()
        let backingOff = entry("backing off", createdAt: 1)
        h.api.failFirstPost(of: backingOff.id)
        h.outbox.enqueue(backingOff)
        // Its first attempt fails (a timeout: it may have landed), so it waits out a backoff.
        await waitUntil { h.outbox.entries.first?.attempts == 1 }
        XCTAssertEqual(h.outbox.entries.first?.state, .queued, "the setup: a retry is pending")
        let gate = Rendezvous()
        h.api.withdrawGate = gate
        h.api.withdrawAnswer = answer(withdrawnClientIds: [backingOff.id])

        let undo = Task { await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts) }
        await waitUntil { !h.api.withdrawCalls.isEmpty }
        h.outbox.retryNow()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(h.api.postedIds, [backingOff.id], "the entry is not re-sent while it is being withdrawn")

        await gate.open()
        _ = await undo.value
    }

    func testNothingAtAllSaysNothingToUndoOnlyWhenAsked() async {
        let h = makeHarness()
        h.api.withdrawAnswer = answer()

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(summary, UndoSendSummary())
        XCTAssertEqual(summary.toast(announceNothing: true), "Nothing to undo")
        XCTAssertNil(summary.toast(announceNothing: false))
    }

    // MARK: - The files of a message that comes back

    func testAFileOnlyMessageThatNeverLeftComesBackWithItsBytesAndCountsAsRestored() async {
        let h = makeHarness()
        let head = entry("head, in the air", createdAt: 1)
        h.api.hold(head.id)
        h.outbox.enqueue(head)
        await waitUntil { h.api.postedIds == [head.id] }
        h.outbox.enqueue(entryWithFile("", file: "notes.txt", createdAt: 2), inlineFileData: fileData("notes.txt"))
        h.api.withdrawAnswer = answer(withdrawnClientIds: [head.id])

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.returned.batches.count, 1)
        XCTAssertEqual(h.returned.batches.first?.key, "s1")
        XCTAssertEqual(h.returned.batches.first?.files.first?.data, Data("notes.txt".utf8))
        XCTAssertEqual(h.returned.batches.first?.supersededUploadIds, ["upload-notes.txt"])
        XCTAssertEqual(summary.restored, 2, "messages, not texts")
        await h.api.release(head.id, answer: .failure(.transport("cleanup")))
    }

    func testAMessageTheServerTombstonedGetsItsInlineFilesBack() async {
        let h = makeHarness()
        let inTheAir = entryWithFile("never arrived", file: "a.txt", createdAt: 1)
        h.api.hold(inTheAir.id)
        h.outbox.enqueue(inTheAir, inlineFileData: fileData("a.txt"))
        await waitUntil { h.api.postedIds == [inTheAir.id] }
        // No row: the server holds no message by this id and only noted that it must refuse it.
        h.api.withdrawAnswer = answer(withdrawnClientIds: [inTheAir.id])

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.returned.names, ["a.txt"])
        XCTAssertEqual(summary.restored, 1)
        await h.api.release(inTheAir.id, answer: .failure(.transport("cleanup")))
    }

    func testARowTheServerWithdrewTakesItsFilesBackOntoTheDraftSoNothingIsStagedAgain() async {
        let h = makeHarness()
        let arrived = entryWithFile("arrived", file: "b.txt", createdAt: 1)
        h.api.hold(arrived.id)
        h.outbox.enqueue(arrived, inlineFileData: fileData("b.txt"))
        await waitUntil { h.api.postedIds == [arrived.id] }
        h.api.withdrawAnswer = answer(
            withdrawn: [WithdrawnSend(id: 42, text: "arrived", clientMessageId: arrived.id)],
            withdrawnClientIds: [arrived.id])

        let summary = await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertTrue(h.returned.batches.isEmpty, "the server holds the file; staging it again would show it twice")
        XCTAssertEqual(summary.restored, 1)
        await h.api.release(arrived.id, answer: .failure(.transport("cleanup")))
    }

    func testRowsTheServerMovedBackOntoTheDraftShowInTheComposerWithoutWaitingForThePoll() async {
        let h = makeHarness()
        let arrived = entry("arrived", createdAt: 1)
        h.api.hold(arrived.id)
        h.outbox.enqueue(arrived)
        await waitUntil { h.api.postedIds == [arrived.id] }
        h.api.withdrawAnswer = answer(
            withdrawn: [WithdrawnSend(id: 42, text: "arrived", clientMessageId: arrived.id)],
            withdrawnClientIds: [arrived.id])
        h.draftsApi.rows = [
            Draft(
                key: "s1", text: "arrived", sessionType: nil, workingDir: nil, updatedAt: nil, version: 5,
                attachments: [
                    DraftAttachment(
                        id: "fresh-id", filename: "photo.png", path: "/p", size: 0, contentType: nil,
                        state: "stored", createdAt: "")
                ])
        ]

        await h.outbox.undoSend(sessionId: "s1", drafts: h.drafts)

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments.map(\.filename), ["photo.png"])
        await h.api.release(arrived.id, answer: .failure(.transport("cleanup")))
    }

    func testARefusalGivesTheFilesBackOnlyWhenItPutsTheTextBack() async {
        for textInDraft in [false, true] {
            let h = makeHarness()
            let sent = entryWithFile("refused", file: "c.txt", createdAt: 1)
            h.api.hold(sent.id)
            h.outbox.enqueue(sent, inlineFileData: fileData("c.txt"))
            await waitUntil { h.api.postedIds == [sent.id] }

            await h.api.release(
                sent.id,
                answer: .success(
                    PostMessageResponse(
                        sessionId: "s1", messageId: 9, duplicate: true, withdrawn: true, textInDraft: textInDraft)))
            await waitUntil { h.outbox.entries.isEmpty }

            XCTAssertEqual(h.returned.names, textInDraft ? [] : ["c.txt"], "textInDraft: \(textInDraft)")
        }
    }

    func testPuttingAFailedSendBackReturnsItsTextAndItsInlineFiles() async {
        let h = makeHarness()
        let failing = entryWithFile("too big", file: "d.txt", createdAt: 1)
        h.api.hold(failing.id)
        h.outbox.enqueue(failing, inlineFileData: fileData("d.txt"))
        await waitUntil { h.api.postedIds == [failing.id] }
        await h.api.release(failing.id, answer: .failure(.http(statusCode: 413, reason: "too large")))
        await waitUntil { h.outbox.entries.first?.state == .failed }
        XCTAssertEqual(h.outbox.entries.first?.state, .failed, "the setup: a permanent failure")

        h.outbox.putBackInComposer(id: failing.id, drafts: h.drafts)

        XCTAssertTrue(h.outbox.entries.isEmpty)
        XCTAssertEqual(h.drafts.draft(for: "s1").text, "too big")
        XCTAssertEqual(h.returned.names, ["d.txt"])
    }

    func testStagingReturnedFilesAgainRemovesTheDraftRowsTheirUploadsMayHaveBecome() async {
        let h = makeHarness()
        let returned = OutboxReturnedFiles(
            key: "s1",
            files: [OutboxReturnedFile(localId: "l", filename: "e.txt", mimeType: "text/plain", data: Data())],
            supersededUploadIds: ["u1", "u2"])
        var staged: [String] = []

        returned.restage(into: h.drafts) { key, files in staged = files.map { "\(key):\($0.filename)" } }
        await waitUntil { h.draftsApi.removed.count == 2 }

        XCTAssertEqual(staged, ["s1:e.txt"])
        XCTAssertEqual(h.draftsApi.removed, ["u1", "u2"])
    }
}
