import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// The fixture pieces the offline screenshots stand on: a note save in fixture mode, the conflict
/// it can be told to raise once, the offline switch, and the seeded cache read back by a real
/// store. A wrong key here would otherwise surface as a screenshot of an error screen.
final class NoteOfflineFixturesTests: XCTestCase {

    override func setUp() {
        super.setUp()
        PaiFixtureLaunch.resetRuntimeState()
    }

    override func tearDown() {
        PaiFixtureLaunch.resetRuntimeState()
        super.tearDown()
    }

    private let conflictArguments = ["/app", "-PaiFixtureMode", "-PaiFixtureNoteConflict"]

    /// A save in fixture mode reads back as the text that was sent, under a new hash, so a synced
    /// edit shows the edit rather than snapping back to the fixture body.
    func testANoteSaveAnswersWithTheTextItSent() throws {
        let sent = try JSONSerialization.data(withJSONObject: ["body": "sent text", "expected_hash": "h"])
        let match = PaiFixtureURLProtocol.route(
            method: "PATCH", path: "/api/notes/\(PaiFixtures.noteID)", body: sent, arguments: ["/app"])

        XCTAssertEqual(match.status, 200)
        let saved = try JSONDecoder().decode(NoteDetail.self, from: match.body())
        let fixture = try JSONDecoder().decode(NoteDetail.self, from: PaiFixtures.data(PaiFixtures.noteDetail))
        XCTAssertEqual(saved.body, "sent text")
        XCTAssertNotEqual(saved.contentHash, fixture.contentHash)
    }

    /// The conflict is served once, decodes into the shape the store reads, and carries a body the
    /// store will classify as a real divergence; the save after it succeeds.
    func testTheConflictFlagRefusesTheFirstSaveOnly() throws {
        let path = "/api/notes/\(PaiFixtures.noteID)"
        let first = PaiFixtureURLProtocol.route(method: "PATCH", path: path, arguments: conflictArguments)
        let second = PaiFixtureURLProtocol.route(method: "PATCH", path: path, arguments: conflictArguments)

        XCTAssertEqual(first.status, 409)
        XCTAssertEqual(second.status, 200)
        let conflict = try JSONDecoder().decode(NoteConflict.self, from: first.body())
        let fixture = try JSONDecoder().decode(NoteDetail.self, from: PaiFixtures.data(PaiFixtures.noteDetail))
        XCTAssertEqual(
            NoteBodyDivergence.of(
                server: conflict.body, base: fixture.body,
                local: fixture.body + PaiFixtures.notePendingEditSuffix),
            .real)
    }

    /// The bridge's switch wins over the launch flag in both directions.
    func testTheOfflineSwitchOverridesTheLaunchFlag() {
        let offlineLaunch = ["/app", "-PaiFixtureMode", "-PaiFixtureOffline"]
        XCTAssertTrue(PaiFixtureLaunch.isOffline(arguments: offlineLaunch))
        PaiFixtureLaunch.setOffline(false)
        XCTAssertFalse(PaiFixtureLaunch.isOffline(arguments: offlineLaunch))
        PaiFixtureLaunch.setOffline(true)
        XCTAssertTrue(PaiFixtureLaunch.isOffline(arguments: ["/app"]))
    }

    /// A store over the seeded storages, with no network, shows what the offline screenshots
    /// photograph: the index, the note, its files, and the edit waiting to sync. Seeding again on
    /// the next launch duplicates nothing.
    @MainActor
    func testASeededCacheOpensOfflineWithThePendingEdit() async throws {
        let cache = InMemoryNotesCacheStorage()
        let outbox = InMemoryNoteOutboxStorage()
        let arguments = ["/app", "-PaiFixtureMode", "-PaiFixtureNotesCacheSeeded", "-PaiFixtureNotePendingEdit"]
        let pdf = Data("%PDF-1.4 fixture".utf8)
        PaiFixtureNotesSeed.seed(cache: cache, outbox: outbox, pdf: pdf, arguments: arguments)
        PaiFixtureNotesSeed.seed(cache: cache, outbox: outbox, pdf: pdf, arguments: arguments)

        let store = NotesStore(api: UnreachableNotesApi(), cache: cache, outbox: outbox)
        store.setPathSatisfied(false)
        await store.loadNote(id: PaiFixtures.noteID)

        XCTAssertEqual(store.notes.count, 3)
        XCTAssertEqual(outbox.loadEdits().count, 1)
        XCTAssertEqual(store.saveState(for: PaiFixtures.noteID), .waitingForNetwork)
        XCTAssertTrue(store.body(for: PaiFixtures.noteID)?.hasSuffix(PaiFixtures.notePendingEditSuffix) == true)
        let pdfResult = try await store.fetchAttachment(containerId: "c1", path: "attachments/spec.pdf")
        guard case .ok(let bytes) = pdfResult else { return XCTFail("the seeded PDF is not served") }
        XCTAssertEqual(bytes, pdf)
        let inventory = try await store.listAttachments(containerId: "c1")
        XCTAssertEqual(inventory.count, 2)
        XCTAssertEqual(cache.loadAttachmentManifest().count, 2)
    }
}

/// Every request fails as it does with no network.
private final class UnreachableNotesApi: NotesApiClient, @unchecked Sendable {
    private func fail<T>() throws -> T { throw URLError(.notConnectedToInternet) }
    func getNotesConfig() async throws -> NotesConfig { try fail() }
    func getNotes(containerId: String?, favourite: Bool?, limit: Int, offset: Int) async throws -> [NoteSummary] {
        try fail()
    }
    func getNote(id: String) async throws -> NoteDetail { try fail() }
    func patchNote(
        id: String, body: String?, frontmatter: String?, name: String?, summary: String?, favourite: Bool?,
        containerId: String?, expectedHash: String?, source: String?
    ) async throws -> NoteSaveResult { try fail() }
    func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail {
        try fail()
    }
    func deleteNote(id: String) async throws -> Bool { try fail() }
    func undeleteNote(id: String) async throws -> NoteDetail { try fail() }
    func getNoteLinks(id: String) async throws -> NoteLinkGraph { try fail() }
    func listNoteRevisions(id: String) async throws -> [NoteRevisionSummary] { try fail() }
    func getNoteRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail { try fail() }
    func restoreNoteRevision(noteId: String, revisionId: String) async throws -> NoteDetail { try fail() }
    func searchNotes(q: String, containerId: String?, limit: Int?, window: TimeBounds?) async throws -> NoteSearchPage {
        try fail()
    }
    func getNoteContainers() async throws -> [NoteContainer] { try fail() }
    func createNoteContainer(path: String, name: String, agentSlug: String?, isDefault: Bool) async throws
        -> NoteContainer
    { try fail() }
    func patchNoteContainer(id: String, name: String?, enabled: Bool?, isDefault: Bool?) async throws
        -> NoteContainer
    { try fail() }
    func deleteNoteContainer(id: String) async throws -> Bool { try fail() }
    func resumeNoteContainer(id: String, action: NoteContainerResumeAction) async throws -> NoteContainer {
        try fail()
    }
    func validateNoteContainerPath(path: String, agentSlug: String?) async throws -> NoteContainerPathCheck {
        try fail()
    }
    func getNoteLinkHealth(containerId: String) async throws -> NoteLinkHealth { try fail() }
    func getNoteAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult { try fail() }
    func uploadNoteAttachment(containerId: String, filename: String, mimeType: String, data: Data) async throws
        -> NoteAttachmentUploaded
    { try fail() }
    func listNoteAttachments(containerId: String) async throws -> [NoteAttachmentRecord] { try fail() }
    func deleteNoteAttachment(containerId: String, path: String) async throws -> Bool { try fail() }
    func renameNoteAttachment(containerId: String, fromPath: String, toPath: String) async throws
        -> NoteAttachmentRecord
    { try fail() }
}
