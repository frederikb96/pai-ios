import Foundation
import XCTest

@testable import PAIKit

private final class ServedDraftsApi: DraftsFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var _rows: [Draft] = []
    var rows: [Draft] {
        get { lock.withLock { _rows } }
        set { lock.withLock { _rows = newValue } }
    }

    func getDrafts() async throws -> [Draft] { rows }
    func putDraft(
        key: String, text: String, deviceId: String?, sessionType: String?, workingDir: String?, model: String?,
        thinking: String?
    ) async throws -> DraftWriteResult {
        DraftWriteResult(key: key, version: 1, previousText: nil)
    }
    func deleteDraft(key: String) async throws -> PaiDraftDeleteResult {
        PaiDraftDeleteResult(key: key, version: 1, previousText: nil)
    }
    func addDraftAttachment(key: String, file: PaiFileUpload, id: String) async throws -> DraftAttachment {
        attachment(id)
    }
    func removeDraftAttachment(key: String, attachmentId: String) async throws {}
}

/// Holds every POST until the test opens the gate, then answers with `answer`.
private final class GatedSender: OutboxSending, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    var answer: Result<PostMessageResponse, PaiError> = .success(PostMessageResponse(sessionId: "s1", messageId: 1))
    private var _superseded: [[String]] = []
    var superseded: [[String]] { lock.withLock { _superseded } }

    func openGate() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            open = true
            defer { continuations = [] }
            return continuations
        }
        for continuation in waiting { continuation.resume() }
    }

    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], supersededUploadIds: [String], sessionType: String?, workingDir: String?,
        agent: String?, model: String?,
        thinking: String?, clientMode: String?, heldTake: HeldTake?
    ) async throws -> PostMessageResponse {
        lock.withLock { _superseded.append(supersededUploadIds) }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if open { return true }
                continuations.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return try answer.get()
    }
}

private func attachment(_ id: String, state: String = "stored") -> DraftAttachment {
    DraftAttachment(
        id: id, filename: "\(id).jpg", path: "/tmp/\(id).jpg", size: 10, contentType: "image/jpeg",
        state: state, createdAt: "t1")
}

private func row(_ key: String, attachments: [DraftAttachment]) -> Draft {
    Draft(
        key: key, text: "", sessionType: nil, workingDir: nil, updatedAt: nil, version: 1,
        attachments: attachments)
}

/// A draft poll can list attachment rows the backend has not claimed yet (the send is still on
/// its way) or list them from a response produced before the claim. Either way the composer must
/// not draw a chip for a file an outgoing or sent message already names.
@MainActor
final class OutboxNamedAttachmentsTests: XCTestCase {

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    private struct Harness {
        let outbox: OutboxStore
        let drafts: DraftStore
        let served: ServedDraftsApi
        let sender: GatedSender
    }

    private func makeHarness() -> Harness {
        let sender = GatedSender()
        let served = ServedDraftsApi()
        let outbox = OutboxStore(api: sender, storage: OutboxInMemoryStorage())
        let drafts = DraftStore(api: served)
        outbox.installHandover(
            drafts: drafts, sessions: SessionListStore(api: FakeSessionListApi()), handoff: NewSessionHandoff())
        return Harness(outbox: outbox, drafts: drafts, served: served, sender: sender)
    }

    private func sendNaming(_ ids: [String], _ h: Harness) -> OutboxEntry {
        let entry = OutboxEntry(target: .session(sessionId: "s1"), text: "look", draftAttachmentIds: ids)
        h.outbox.enqueue(entry)
        return entry
    }

    private func sendCarryingInline(_ uploadId: String, _ h: Harness) -> OutboxEntry {
        let entry = OutboxEntry(
            target: .session(sessionId: "s1"), text: "look", supersededUploadIds: [uploadId])
        h.outbox.enqueue(entry)
        return entry
    }

    func testAnUploadAnsweredAfterTheSendTookItsFileDrawsNoChip() async {
        let h = makeHarness()
        _ = sendCarryingInline("u1", h)

        let file = PaiFileUpload(filename: "paste-1.png", mimeType: "image/png", data: Data([1]))
        let answered = await h.drafts.addAttachment(key: "s1", file: file, id: "u1")

        XCTAssertNotNil(answered)
        XCTAssertEqual(h.drafts.draft(for: "s1").attachments, [])
        h.sender.openGate()
    }

    func testARowLandingWhileTheSendIsOnItsWayDrawsNoChip() async {
        let h = makeHarness()
        _ = sendCarryingInline("u1", h)
        h.served.rows = [row("s1", attachments: [attachment("u1")])]

        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments, [])
        h.sender.openGate()
    }

    func testTheSendNamesTheUploadItCarriesInline() async {
        let h = makeHarness()
        h.sender.openGate()
        _ = sendCarryingInline("u1", h)

        await waitUntil { !h.sender.superseded.isEmpty }

        XCTAssertEqual(h.sender.superseded, [["u1"]])
    }

    func testAnInlineUploadComesBackWhenTheMessageIsDiscardedUnsent() async {
        let h = makeHarness()
        let entry = sendCarryingInline("u1", h)
        h.served.rows = [row("s1", attachments: [attachment("u1")])]

        h.outbox.discard(id: entry.id)
        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments.map(\.id), ["u1"])
    }

    func testAnEntryPersistedWithoutSupersededUploadsStillDecodes() throws {
        let saved = OutboxEntry(target: .session(sessionId: "s1"), text: "look", draftAttachmentIds: ["a1"])
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        json.removeValue(forKey: "supersededUploadIds")

        let decoded = try JSONDecoder().decode(
            OutboxEntry.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertEqual(decoded.namedAttachmentIds, ["a1"])
    }

    func testAPollWhileTheSendIsStillQueuedDoesNotBringTheChipBack() async {
        let h = makeHarness()
        h.served.rows = [row("s1", attachments: [attachment("a1")])]
        await h.drafts.syncFromServer()
        XCTAssertEqual(h.drafts.draft(for: "s1").attachments.map(\.id), ["a1"])

        _ = sendNaming(["a1"], h)
        XCTAssertEqual(h.drafts.draft(for: "s1").attachments, [], "gone the moment Send is pressed")

        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments, [], "the server has not claimed the row yet")
        h.sender.openGate()
    }

    func testAPollAnsweredBeforeTheClaimButDeliveredAfterTheSendLandedDoesNotBringTheChipBack() async {
        let h = makeHarness()
        h.served.rows = [row("s1", attachments: [attachment("a1")])]
        await h.drafts.syncFromServer()
        let entry = sendNaming(["a1"], h)
        h.sender.openGate()
        await waitUntil { !h.outbox.entries.contains { $0.id == entry.id } }
        XCTAssertTrue(h.outbox.entries.isEmpty, "the landed send is retired")

        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments, [], "a stale response still lists the row")
    }

    func testAnAttachmentUploadedAfterTheSendStillShows() async {
        let h = makeHarness()
        h.served.rows = [row("s1", attachments: [attachment("a1")])]
        await h.drafts.syncFromServer()
        _ = sendNaming(["a1"], h)

        h.served.rows = [row("s1", attachments: [attachment("a1"), attachment("a2")])]
        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments.map(\.id), ["a2"])
        h.sender.openGate()
    }

    func testARowTheServerCouldNotClaimStaysVisibleAfterTheSend() async {
        let h = makeHarness()
        h.served.rows = [row("s1", attachments: [attachment("a1")])]
        await h.drafts.syncFromServer()
        _ = sendNaming(["a1"], h)
        h.served.rows = [row("s1", attachments: [attachment("a1", state: "unclaimed")])]

        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments.map(\.state), ["unclaimed"])
        h.sender.openGate()
    }

    func testADiscardedUnsentMessageGivesItsAttachmentsBack() async {
        let h = makeHarness()
        h.sender.answer = .failure(.http(statusCode: 400, reason: "bad"))
        h.served.rows = [row("s1", attachments: [attachment("a1")])]
        await h.drafts.syncFromServer()
        let entry = sendNaming(["a1"], h)
        h.sender.openGate()
        await waitUntil { h.outbox.entries.first?.state == .failed }
        XCTAssertEqual(h.outbox.entries.first?.state, .failed)
        await h.drafts.syncFromServer()
        XCTAssertEqual(h.drafts.draft(for: "s1").attachments, [], "a failed send still owns its files")

        h.outbox.discard(id: entry.id)
        await h.drafts.syncFromServer()

        XCTAssertEqual(h.drafts.draft(for: "s1").attachments.map(\.id), ["a1"])
    }

    func testAMessageQueuedBeforeARelaunchStillHidesItsAttachments() async {
        let sender = GatedSender()
        let served = ServedDraftsApi()
        let storage = OutboxInMemoryStorage()
        storage.saveEntries([
            OutboxEntry(target: .session(sessionId: "s1"), text: "look", draftAttachmentIds: ["a1"])
        ])
        let outbox = OutboxStore(api: sender, storage: storage)
        let drafts = DraftStore(api: served)
        outbox.installHandover(
            drafts: drafts, sessions: SessionListStore(api: FakeSessionListApi()), handoff: NewSessionHandoff())
        served.rows = [row("s1", attachments: [attachment("a1")])]

        await drafts.syncFromServer()

        XCTAssertEqual(drafts.draft(for: "s1").attachments, [])
        sender.openGate()
    }
}
