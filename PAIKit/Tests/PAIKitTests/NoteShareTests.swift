import XCTest

@testable import PAIKit

/// A `GET /api/notes/{id}/share` answer in the shape the backend's route builds it
/// (`notes_share_api.get_note_share_route`, `share_store.blob_to_dict`/`limits_to_dict`).
private let shareJSON = """
    {"note_id":"n1",
     "links":{"read":{"kind":"read","url":"https://text.example.net/n/#r-token","created_at_ms":1700000000000,"aliases":["oldId"]},
              "edit":null},
     "viewers":2,
     "outgoing":[
       {"rel_path":"attachments/a.png","name":"a.png","size_bytes":10,"mtime_ms":5,"reason":"new",
        "requested_by_visitor":false,"too_large":false},
       {"rel_path":"attachments/b.png","name":"b.png","size_bytes":20,"mtime_ms":6,"reason":"changed",
        "requested_by_visitor":true,"too_large":false},
       {"rel_path":"attachments/huge.mov","name":"huge.mov","size_bytes":99999999,"mtime_ms":7,"reason":"new",
        "requested_by_visitor":false,"too_large":true}],
     "incoming":[
       {"id":"b1","name":"up-ab12cd.png","rel_path":"attachments/up-ab12cd.png","size_bytes":30,
        "content_type":"image/png","origin":"public","created_at_ms":1700000001000}],
     "sandbox":[
       {"id":"b0","name":"c.png","rel_path":"attachments/c.png","size_bytes":40,
        "content_type":"image/png","origin":"vault","created_at_ms":1700000002000},
       {"id":"b1","name":"up-ab12cd.png","rel_path":"attachments/up-ab12cd.png","size_bytes":30,
        "content_type":"image/png","origin":"public","created_at_ms":1700000001000}],
     "sandbox_bytes":70,
     "limits":{"body_max_bytes":524288,"upload_max_bytes":52428800,"sandbox_max_bytes":209715200,
               "sandbox_max_files":100,"publish_max_bytes":15728640}}
    """

private func decodeShare(_ json: String = shareJSON) throws -> NoteShare {
    try JSONDecoder().decode(NoteShare.self, from: Data(json.utf8))
}

final class NoteShareWireTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    func testTheShareAnswerDecodesEveryNestedShape() throws {
        let share = try decodeShare()
        XCTAssertEqual(share.noteId, "n1")
        XCTAssertEqual(share.links.read?.url, "https://text.example.net/n/#r-token")
        XCTAssertEqual(share.links.read?.aliases, ["oldId"])
        XCTAssertNil(share.links.edit)
        XCTAssertEqual(share.viewers, 2)
        XCTAssertEqual(
            share.outgoing.map(\.relPath), ["attachments/a.png", "attachments/b.png", "attachments/huge.mov"])
        XCTAssertEqual(share.outgoing[1].requestedByVisitor, true)
        XCTAssertEqual(share.outgoing[2].tooLarge, true)
        XCTAssertEqual(share.incoming.first?.origin, .public)
        XCTAssertEqual(share.sandbox.first?.origin, .vault)
        XCTAssertEqual(share.sandboxBytes, 70)
        XCTAssertEqual(share.limits.publishMaxBytes, 15_728_640)
        XCTAssertEqual(share.limits.sandboxMaxFiles, 100)
    }

    func testAnUnknownBlobOriginDegradesInsteadOfFailingTheWholeAnswer() throws {
        let json = shareJSON.replacingOccurrences(of: #""origin":"public""#, with: #""origin":"quarantine""#)
        XCTAssertEqual(try decodeShare(json).incoming.first?.origin, .unrecognized("quarantine"))
    }

    func testDeleteAndBatchAndStateAndResolveAnswersDecode() throws {
        let deleted = try JSONDecoder().decode(
            NoteShareDeleted.self,
            from: Data(#"{"deleted":true,"sandbox_dropped":true,"discarded_uploads":3}"#.utf8))
        XCTAssertEqual(deleted, NoteShareDeleted(deleted: true, sandboxDropped: true, discardedUploads: 3))
        let batch = try JSONDecoder().decode(
            NoteShareItemResults.self,
            from: Data(
                #"{"results":[{"key":"attachments/a.png","ok":true},{"key":"b1","ok":false,"error":"gone"}]}"#.utf8))
        XCTAssertEqual(batch.results.map(\.ok), [true, false])
        XCTAssertEqual(batch.results[1].error, "gone")
        let state = try JSONDecoder().decode(
            NoteState.self, from: Data(#"{"content_hash":"sha256:x","viewers":4}"#.utf8))
        XCTAssertEqual(state, NoteState(contentHash: "sha256:x", viewers: 4))
        let resolved = try JSONDecoder().decode(
            NoteShareResolved.self, from: Data(#"{"note_id":"n1","kind":"edit"}"#.utf8))
        XCTAssertEqual(resolved.kind, .edit)
    }

    /// `shared` is on the list row and the detail, and an older backend sends neither.
    func testTheSharedMarkDecodesOnSummaryAndDetailAndSurvivesRebuilds() throws {
        let row = try JSONDecoder().decode(
            NoteSummary.self,
            from: Data(
                #"{"id":"n1","name":"N","summary":null,"container_id":"c","favourite":false,"tags":[],"updated_at_ms":1,"pending_delete":false,"shared":true}"#
                    .utf8))
        XCTAssertEqual(row.shared, true)
        XCTAssertEqual(row.withShared(false).shared, false)
        let old = try JSONDecoder().decode(
            NoteSummary.self,
            from: Data(
                #"{"id":"n1","name":"N","summary":null,"container_id":"c","favourite":false,"tags":[],"updated_at_ms":1,"pending_delete":false}"#
                    .utf8))
        XCTAssertNil(old.shared)
        let detail = NoteDetail(
            id: "n1", name: "N", summary: nil, containerId: "c", favourite: false, tags: [], updatedAtMs: 1,
            pendingDelete: false, frontmatter: nil, body: "b", contentHash: "h", createdAt: nil, createdAtMs: nil,
            lastWriteSource: "share", shared: true)
        XCTAssertEqual(detail.summaryRow.shared, true, "the list row built from a detail keeps the mark")
        let conflict = NoteConflict(currentHash: "h2", updatedAtMs: 2, frontmatter: nil, body: "b2")
        XCTAssertEqual(detail.adoptingHash(conflict).shared, true)
        XCTAssertEqual(detail.withShared(false).lastWriteSource, "share")
    }

    // MARK: Requests

    private func makeClient(stub body: String = "{}") throws -> PaiApiClient {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        return PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
    }

    private var capturedBody: String { String(data: PaiStubURLProtocol.capturedBody ?? Data(), encoding: .utf8) ?? "" }

    /// The body as parsed JSON — JSONEncoder escapes `/`, so a substring match on a path misleads.
    private var capturedJSON: [String: Any] {
        (try? JSONSerialization.jsonObject(with: PaiStubURLProtocol.capturedBody ?? Data())) as? [String: Any] ?? [:]
    }

    func testLinkRoutesUseTheKindAsThePathSegmentAndPutAndDeleteCarryNoBody() async throws {
        let client = try makeClient(stub: #"{"kind":"edit","url":"u","created_at_ms":1,"aliases":[]}"#)
        _ = try await client.putNoteShare(noteId: "n1", kind: .edit)
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/n1/share/edit")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "PUT")

        let deleter = try makeClient(stub: #"{"deleted":true,"sandbox_dropped":false,"discarded_uploads":0}"#)
        _ = try await deleter.deleteNoteShare(noteId: "n1", kind: .read)
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/n1/share/read")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.httpMethod, "DELETE")
    }

    func testBatchRoutesSendTheirOwnBodyKey() async throws {
        let client = try makeClient(stub: #"{"results":[]}"#)
        _ = try await client.publishNoteShareAttachments(noteId: "n1", relPaths: ["attachments/a.png"])
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/n1/share/attachments/publish")
        XCTAssertEqual(capturedJSON["rel_paths"] as? [String], ["attachments/a.png"])

        _ = try await client.acceptNoteShareAttachments(noteId: "n1", blobIds: ["b1"])
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/n1/share/attachments/accept")
        XCTAssertEqual(capturedJSON["blob_ids"] as? [String], ["b1"])

        _ = try await client.discardNoteShareAttachments(noteId: "n1", blobIds: ["b1"])
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/n1/share/attachments/discard")
    }

    func testThePresencePollNamesItsTabAndTheResolveBodyCarriesTheToken() async throws {
        let client = try makeClient(stub: #"{"content_hash":"h","viewers":1}"#)
        _ = try await client.getNoteState(noteId: "n1", clientId: "abc-123")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/n1/state")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.query, "client_id=abc-123")

        let resolver = try makeClient(stub: #"{"note_id":"n1","kind":"read"}"#)
        _ = try await resolver.resolveNoteShare(token: "tok")
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/api/notes/shares/resolve")
        XCTAssertTrue(capturedBody.contains(#""token":"tok""#), capturedBody)
    }

    func testAMissingSandboxFileIsNotFoundRatherThanAnError() async throws {
        PaiStubURLProtocol.stub = .init(statusCode: 404, headers: [:], body: Data(#"{"detail":"x"}"#.utf8))
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        let result = try await client.getNoteShareAttachment(noteId: "n1", blobId: "b1")
        guard case .notFound = result else { return XCTFail("a 404 must read as notFound, got \(result)") }
    }
}

actor FakeNoteShareApi: NoteShareApiClient {
    var share: NoteShare
    private(set) var calls: [String] = []
    var itemResults: [NoteShareItemResult]?
    var failure: PaiError?

    init(share: NoteShare) { self.share = share }

    func setShare(_ share: NoteShare) { self.share = share }
    func setFailure(_ failure: PaiError?) { self.failure = failure }
    func setItemResults(_ results: [NoteShareItemResult]?) { itemResults = results }

    private func record(_ call: String) throws {
        calls.append(call)
        if let failure { throw failure }
    }

    func getNoteShare(noteId: String) async throws -> NoteShare {
        try record("get")
        return share
    }

    func putNoteShare(noteId: String, kind: NoteShareKind) async throws -> NoteShareLink {
        try record("put:\(kind.rawValue)")
        return NoteShareLink(kind: kind, url: "https://x/n/#\(kind.rawValue)", createdAtMs: 1)
    }

    func deleteNoteShare(noteId: String, kind: NoteShareKind) async throws -> NoteShareDeleted {
        try record("delete:\(kind.rawValue)")
        return NoteShareDeleted(deleted: true, sandboxDropped: false, discardedUploads: 0)
    }

    private func results(for keys: [String]) -> NoteShareItemResults {
        NoteShareItemResults(results: itemResults ?? keys.map { NoteShareItemResult(key: $0, ok: true) })
    }

    func publishNoteShareAttachments(noteId: String, relPaths: [String]) async throws -> NoteShareItemResults {
        try record("publish:" + relPaths.joined(separator: ","))
        return results(for: relPaths)
    }

    func acceptNoteShareAttachments(noteId: String, blobIds: [String]) async throws -> NoteShareItemResults {
        try record("accept:" + blobIds.joined(separator: ","))
        return results(for: blobIds)
    }

    func discardNoteShareAttachments(noteId: String, blobIds: [String]) async throws -> NoteShareItemResults {
        try record("discard:" + blobIds.joined(separator: ","))
        return results(for: blobIds)
    }

    func getNoteShareAttachment(noteId: String, blobId: String) async throws -> NoteAttachmentResult {
        try record("preview:\(blobId)")
        return .ok(Data([1, 2, 3]))
    }

    func getNoteState(noteId: String, clientId: String) async throws -> NoteState {
        try record("state:\(clientId)")
        return NoteState(contentHash: "h", viewers: share.viewers)
    }
}

@MainActor
final class NoteShareStoreTests: XCTestCase {

    private func make(_ json: String = shareJSON) async throws -> (NoteShareStore, FakeNoteShareApi, SharedFlag) {
        let api = FakeNoteShareApi(share: try decodeShare(json))
        let flag = SharedFlag()
        let store = NoteShareStore(noteId: "n1", api: api) { flag.value = $0 }
        await store.load()
        return (store, api, flag)
    }

    final class SharedFlag { var value: Bool? }

    func testLoadReportsWhetherAnyLinkExistsSoTheListMarkFollows() async throws {
        let (store, _, flag) = try await make()
        XCTAssertEqual(flag.value, true)
        XCTAssertTrue(store.hasAnyLink)
        XCTAssertEqual(
            store.pendingCount, 3,
            "two publishable outgoing files (one visitor-requested, still counted) plus one upload; the too-large file is not"
        )
    }

    /// A file a visitor's edit named, and one too big to send, are never swept up by "Publish all".
    func testPublishAllLeavesOutVisitorRequestedAndOversizeFiles() async throws {
        let (store, api, _) = try await make()
        XCTAssertEqual(store.publishAllCandidates.map(\.relPath), ["attachments/a.png"])
        XCTAssertEqual(store.heldBackFromPublishAll, 2)
        await store.publishAll()
        let calls = await api.calls
        XCTAssertTrue(calls.contains("publish:attachments/a.png"), "\(calls)")
        XCTAssertFalse(calls.contains { $0.contains("b.png") || $0.contains("huge") }, "\(calls)")
    }

    func testAnExplicitPublishOfAVisitorRequestedFileGoesThrough() async throws {
        let (store, api, _) = try await make()
        await store.publish(["attachments/b.png"])
        let calls = await api.calls
        XCTAssertTrue(calls.contains("publish:attachments/b.png"))
    }

    func testAcceptAllAndDiscardAllCoverEveryWaitingUpload() async throws {
        let (store, api, _) = try await make()
        await store.acceptAll()
        await store.discardAll()
        let calls = await api.calls
        XCTAssertTrue(calls.contains("accept:b1"))
        XCTAssertTrue(calls.contains("discard:b1"))
    }

    /// The queues are derived server-side, so an action ends with a fresh read.
    func testEveryActionEndsWithARereadOfTheShareAnswer() async throws {
        let (store, api, _) = try await make()
        let before = await api.calls.filter { $0 == "get" }.count
        await store.accept(["b1"])
        let after = await api.calls.filter { $0 == "get" }.count
        XCTAssertEqual(after, before + 1)
    }

    func testAPartialFailureIsReportedByNameAndReturnsFalse() async throws {
        let (store, api, _) = try await make()
        await api.setItemResults([
            NoteShareItemResult(key: "b1", ok: false, error: "the vault already holds it")
        ])
        let ok = await store.accept(["b1"])
        XCTAssertFalse(ok)
        XCTAssertEqual(store.errorMessage, "Could not accept: b1 — the vault already holds it")
    }

    func testDeletingTheLastLinkWarnsOnlyWhileUploadsAreUnaccepted() async throws {
        let (store, _, _) = try await make()
        XCTAssertEqual(
            store.deleteWarning(for: .read),
            "This is the last link. 1 uploaded file nobody accepted yet will be discarded with it.")
        XCTAssertNil(store.deleteWarning(for: .edit), "there is no edit link to delete")
    }

    func testNoWarningWhenAnotherLinkRemainsOrNothingIsWaiting() async throws {
        let base = try decodeShare()
        let edit = NoteShareLink(kind: .edit, url: "u2", createdAtMs: 2)
        let twoLinks = try await make(share: withLinks(base, read: base.links.read, edit: edit))
        XCTAssertNil(twoLinks.0.deleteWarning(for: .read), "the sandbox survives while a link remains")

        let noUploads = try await make(share: withIncoming(base, []))
        XCTAssertNil(noUploads.0.deleteWarning(for: .read), "nothing unaccepted is lost")
    }

    private func make(share: NoteShare) async throws -> (NoteShareStore, FakeNoteShareApi) {
        let api = FakeNoteShareApi(share: share)
        let store = NoteShareStore(noteId: "n1", api: api)
        await store.load()
        return (store, api)
    }

    private func withLinks(_ s: NoteShare, read: NoteShareLink?, edit: NoteShareLink?) -> NoteShare {
        NoteShare(
            noteId: s.noteId, links: .init(read: read, edit: edit), viewers: s.viewers, outgoing: s.outgoing,
            incoming: s.incoming, sandbox: s.sandbox, sandboxBytes: s.sandboxBytes, limits: s.limits)
    }

    private func withIncoming(_ s: NoteShare, _ incoming: [NoteShareBlob]) -> NoteShare {
        NoteShare(
            noteId: s.noteId, links: s.links, viewers: s.viewers, outgoing: s.outgoing, incoming: incoming,
            sandbox: s.sandbox, sandboxBytes: s.sandboxBytes, limits: s.limits)
    }

    func testCreatingAndDeletingALinkCallTheRightRoutesAndRefresh() async throws {
        let (store, api, _) = try await make()
        let link = await store.createLink(.edit)
        XCTAssertEqual(link?.kind, .edit)
        _ = await store.deleteLink(.read)
        let calls = await api.calls
        XCTAssertTrue(calls.contains("put:edit"))
        XCTAssertTrue(calls.contains("delete:read"))
    }

    /// A failed read must not blank the queue: an empty list reads as "nothing waiting".
    func testAFailedRefreshKeepsTheHeldAnswer() async throws {
        let (store, api, _) = try await make()
        await api.setFailure(.transport("offline"))
        let ok = await store.refresh()
        XCTAssertFalse(ok)
        XCTAssertEqual(store.pendingCount, 3)
        XCTAssertEqual(store.errorMessage, "offline")
    }

    func testPresenceCountsThroughOneClientIdAndKeepsTheLastCountOnAFailedPoll() async throws {
        let api = FakeNoteShareApi(share: try decodeShare())
        let presence = NotePresenceStore(api: api, clientId: "tab-1")
        await presence.pollOnce(noteId: "n1")
        XCTAssertEqual(presence.viewers, 2)
        await api.setFailure(.transport("offline"))
        await presence.pollOnce(noteId: "n1")
        XCTAssertEqual(presence.viewers, 2, "a failed poll is not zero viewers")
        let calls = await api.calls
        XCTAssertEqual(calls.first, "state:tab-1")
    }
}

final class NoteShareDisplayTests: XCTestCase {

    private func blob(type: String, size: Int = 100) -> NoteShareBlob {
        NoteShareBlob(
            id: "b", name: "x", relPath: "attachments/x", sizeBytes: size, contentType: type, origin: .public,
            createdAtMs: 0)
    }

    /// A visitor chooses what they upload, so only the four raster types are ever drawn.
    func testOnlyRasterImagesAreDrawnBeforeTheOwnerDecides() {
        for type in ["image/png", "image/jpeg", "image/gif", "image/webp", "IMAGE/PNG"] {
            XCTAssertTrue(blob(type: type).isPreviewableImage, type)
        }
        for type in ["image/svg+xml", "application/pdf", "text/html", "application/octet-stream"] {
            XCTAssertFalse(blob(type: type).isPreviewableImage, type)
        }
    }

    func testAnImageAboveThePreviewCeilingIsNotDecoded() {
        XCTAssertTrue(blob(type: "image/png", size: NoteShareBlob.maxPreviewBytes).isPreviewableImage)
        XCTAssertFalse(blob(type: "image/png", size: NoteShareBlob.maxPreviewBytes + 1).isPreviewableImage)
    }

    func testAShareWriteIsLabelledAsAVisitorEverywhereItIsShown() {
        XCTAssertEqual(NoteWriteSource.infoLabel("share"), "a visitor through a share link")
        XCTAssertEqual(NoteWriteSource.historyLabel("share"), "edited through a share link")
        XCTAssertEqual(NoteWriteSource.infoLabel("ui"), "this app")
        XCTAssertEqual(NoteWriteSource.historyLabel("somethingNew"), "somethingNew")
    }
}
