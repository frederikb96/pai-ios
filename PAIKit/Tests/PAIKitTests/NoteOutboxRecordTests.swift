import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// The pending-edit file on disk. It holds the only copy of what was typed, so it has to stay
/// readable across app updates, and a file that cannot be read must never be overwritten.
final class NoteOutboxRecordTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("note-outbox-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private var editsDirectory: URL { root.appendingPathComponent("edits") }
    private var quarantineDirectory: URL { root.appendingPathComponent("unreadable") }

    private func place(_ json: String, as name: String = "n1.json") throws {
        try Data(json.utf8).write(to: editsDirectory.appendingPathComponent(name))
    }

    /// A record in the first versioned format, as a phone holds it today. A change to the record
    /// type that would strand such a file — a new required key, a renamed one — fails here.
    func testAFrozenVersionOneRecordStillReads() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/note-pending-edit-v1.json")
        let storage = FileNoteOutboxStorage(rootURL: root)
        try FileManager.default.copyItem(at: fixture, to: editsDirectory.appendingPathComponent("trip.json"))

        let edits = storage.loadEdits()

        XCTAssertEqual(edits.count, 1)
        let edit = try XCTUnwrap(edits.first)
        XCTAssertEqual(edit.noteId, "6a0b5f2e-6f1e-4c55-9a43-1c1f4d2b7e10")
        XCTAssertEqual(edit.body, "# Trip\n\n- tent\n- stove, typed on the plane\n")
        XCTAssertEqual(edit.base.contentHash, "sha256:7d793037a0760186574b0282f2f435e7")
        XCTAssertEqual(edit.base.body, "# Trip\n\n- tent\n")
        XCTAssertEqual(edit.base.name, "Trip")
        XCTAssertEqual(edit.base.frontmatter, "tags: [trip]")
        XCTAssertEqual(edit.raisedConflict?.currentHash, "sha256:5d41402abc4b2a76b9719d911017c592")
        XCTAssertEqual(edit.attempts, 2)
        XCTAssertFalse(edit.awaitingSync)
        XCTAssertTrue(storage.loadQuarantined().isEmpty)
    }

    /// What this build writes, the next launch reads back whole.
    func testWhatIsWrittenReadsBackWhole() {
        let base = NoteDetail(
            id: "n1", name: "Note", summary: "s", containerId: "c1", favourite: true, tags: ["a"], updatedAtMs: 3,
            pendingDelete: false, frontmatter: "f: 1", body: "base", contentHash: "h1", createdAt: nil,
            createdAtMs: 2, lastWriteSource: "phone", shared: true)
        let edit = NotePendingEdit(
            noteId: "n1", body: "mine", base: base, editedAtMs: 5, attempts: 1,
            raisedConflict: NoteConflict(currentHash: "h2", updatedAtMs: 4, frontmatter: nil, body: "theirs"),
            awaitingSync: true, waitedForServer: true, refusal: "Note not found")
        FileNoteOutboxStorage(rootURL: root).saveEdit(edit)

        XCTAssertEqual(FileNoteOutboxStorage(rootURL: root).loadEdits(), [edit])
    }

    /// A record missing a key the store can do without still restores, rather than vanishing
    /// from the restore and being overwritten by the next keystroke.
    func testARecordMissingAnOptionalKeyStillRestores() async throws {
        let storage = FileNoteOutboxStorage(rootURL: root)
        try place(
            """
            {"noteId":"n1","body":"typed on the plane","editedAtMs":1,
             "base":{"id":"n1","name":"Note","favourite":false,"tags":[],"updated_at_ms":1,
                     "pending_delete":false,"body":"base","content_hash":"h1"}}
            """)

        let store = await NotesStore(api: UnreachableNotesApi(), outbox: storage)

        let draft = await store.drafts["n1"]
        XCTAssertEqual(draft, "typed on the plane")
    }

    /// A record this build cannot use (here: no hash to make the save conditional on) is moved
    /// aside, its text stays reachable, and typing in the same note afterwards cannot destroy it.
    func testAnUnreadableRecordIsQuarantinedAndItsTextKept() async throws {
        let storage = FileNoteOutboxStorage(rootURL: root)
        try place(
            """
            {"noteId":"n1","body":"typed on the plane","editedAtMs":1,"awaitingSync":true,
             "base":{"id":"n1","name":"Note","body":"base"}}
            """)

        let cache = InMemoryNotesCacheStorage()
        cache.saveBody(
            NoteDetail(
                id: "n1", name: "Note", summary: nil, containerId: nil, favourite: false, tags: [], updatedAtMs: 1,
                pendingDelete: false, frontmatter: nil, body: "base", contentHash: "h1", createdAt: nil,
                createdAtMs: nil, lastWriteSource: nil))
        let store = await NotesStore(api: UnreachableNotesApi(), cache: cache, outbox: storage)
        let kept = await store.keptTexts

        XCTAssertEqual(kept.map(\.text), ["typed on the plane"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: editsDirectory.appendingPathComponent("n1.json").path))

        await store.loadNote(id: "n1")
        await store.edit(id: "n1", body: "base, a new edit")
        await store.flush(id: "n1")
        XCTAssertEqual(storage.loadEdits().map(\.body), ["base, a new edit"])

        XCTAssertEqual(FileNoteOutboxStorage(rootURL: root).loadQuarantined().map(\.text), ["typed on the plane"])

        guard let first = kept.first else { return XCTFail("nothing kept") }
        await store.discardKeptText(first)
        XCTAssertTrue(FileNoteOutboxStorage(rootURL: root).loadQuarantined().isEmpty)
        XCTAssertEqual(storage.loadEdits().map(\.body), ["base, a new edit"], "discarding touches only the kept file")
    }

    /// A file written by a newer format is not half-read; it waits in quarantine. One that is not
    /// even JSON is kept as its raw text.
    func testANewerFormatAndANonJsonFileAreQuarantinedWithTheirText() throws {
        let storage = FileNoteOutboxStorage(rootURL: root)
        try place(
            """
            {"version":2,"noteId":"n1","body":"from a newer build",
             "base":{"body":"base","content_hash":"h1"}}
            """)
        try place("half a write of somethi", as: "n2.json")

        XCTAssertTrue(storage.loadEdits().isEmpty)

        let kept = storage.loadQuarantined()
        XCTAssertEqual(Set(kept.map(\.text)), ["from a newer build", "half a write of somethi"])
        XCTAssertEqual(kept.first { $0.text == "from a newer build" }?.noteId, "n1")
    }
}

/// A notes API that fails every call, for tests that never reach the network.
private struct UnreachableNotesApi: NotesApiClient {
    private func fail<T>() throws -> T { throw URLError(.notConnectedToInternet) }
    func getNotesConfig() async throws -> NotesConfig { try fail() }
    func getNotes(containerId: String?, favourite: Bool?, limit: Int, offset: Int) async throws -> [NoteSummary] {
        try fail()
    }
    func getNote(id: String) async throws -> NoteDetail { try fail() }
    func patchNote(
        id: String, body: String?, frontmatter: String?, name: String?, summary: String?,
        favourite: Bool?, containerId: String?, expectedHash: String?, source: String?
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
