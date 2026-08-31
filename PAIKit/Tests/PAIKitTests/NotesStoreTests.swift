import XCTest
@testable import PAIKit

/// A fake covering every `NotesApiClient` route. Most tests need only the two or three calls
/// their own scenario touches — everything else answers a harmless default rather than throwing,
/// so a new protocol method never has to be scripted into every existing test.
private final class FakeNotesApi: NotesApiClient, @unchecked Sendable {
    private(set) var deleteNoteCalls: [String] = []
    private(set) var undeleteNoteCalls: [String] = []
    private(set) var createNoteCalls: [(name: String, containerId: String?)] = []
    private(set) var patchNoteCalls: [(id: String, name: String?)] = []

    var deleteNoteResult: Bool = true
    var deleteNoteError: (any Error)?
    var undeleteNoteResult: NoteDetail?
    var createNoteResult: NoteDetail?
    var patchNoteResult: NoteSaveResult?
    var restoreRevisionResult: NoteDetail?
    var getNoteLinksResult: NoteLinkGraph = NoteLinkGraph(outgoing: [], backlinks: [], extractionSkipped: false)
    var getNotesResult: [NoteSummary] = []
    var getNoteResult: NoteDetail?

    /// Off by default, so every ordinary test's `getNote` answers immediately. A test driving the
    /// load-vs-save race turns this on and holds the call open with a continuation instead of a
    /// sleep, so the ordering is exact rather than hoped-for.
    var getNoteGateEnabled = false
    private var getNoteStarted: CheckedContinuation<Void, Never>?
    private var getNoteRelease: CheckedContinuation<Void, Never>?

    func getNotes(containerId: String?, favourite: Bool?, limit: Int, offset: Int) async throws -> [NoteSummary] {
        getNotesResult
    }

    /// Suspends until the in-flight `getNote` call is released, resolving as soon as that call
    /// has actually started so a test can then drive something else to completion in between.
    func waitUntilGetNoteStarted() async {
        await withCheckedContinuation { self.getNoteStarted = $0 }
    }

    func releaseGetNote() {
        getNoteRelease?.resume()
        getNoteRelease = nil
    }

    func getNote(id: String) async throws -> NoteDetail {
        guard getNoteGateEnabled else { return getNoteResult ?? NoteFixture.detail(id: id) }
        getNoteStarted?.resume()
        getNoteStarted = nil
        await withCheckedContinuation { self.getNoteRelease = $0 }
        return getNoteResult ?? NoteFixture.detail(id: id)
    }

    func patchNote(
        id: String, body: String?, frontmatter: String?, name: String?, summary: String?,
        favourite: Bool?, containerId: String?, expectedHash: String?
    ) async throws -> NoteSaveResult {
        patchNoteCalls.append((id: id, name: name))
        return patchNoteResult ?? .saved(NoteFixture.detail(id: id, name: name ?? "Untitled"))
    }

    func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail {
        createNoteCalls.append((name: name, containerId: containerId))
        return createNoteResult ?? NoteFixture.detail(id: "new-id", name: name)
    }

    func deleteNote(id: String) async throws -> Bool {
        deleteNoteCalls.append(id)
        if let deleteNoteError { throw deleteNoteError }
        return deleteNoteResult
    }

    func undeleteNote(id: String) async throws -> NoteDetail {
        undeleteNoteCalls.append(id)
        return undeleteNoteResult ?? NoteFixture.detail(id: id, name: "Restored")
    }

    func getNoteLinks(id: String) async throws -> NoteLinkGraph { getNoteLinksResult }
    func listNoteRevisions(id: String) async throws -> [NoteRevisionSummary] { [] }
    func getNoteRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail {
        fatalError("not scripted")
    }
    func restoreNoteRevision(noteId: String, revisionId: String) async throws -> NoteDetail {
        restoreRevisionResult ?? NoteFixture.detail(id: noteId, name: "Restored version")
    }
    func searchNotes(q: String, containerId: String?, limit: Int?) async throws -> NoteSearchPage {
        NoteSearchPage(hits: [], truncated: false)
    }

    func getNoteContainers() async throws -> [NoteContainer] { [] }
    func createNoteContainer(path: String, name: String, agentSlug: String?, isDefault: Bool) async throws
        -> NoteContainer
    { fatalError("not scripted") }
    func patchNoteContainer(id: String, name: String?, enabled: Bool?, isDefault: Bool?) async throws
        -> NoteContainer
    { fatalError("not scripted") }
    func deleteNoteContainer(id: String) async throws -> Bool { true }
    func resumeNoteContainer(id: String, action: NoteContainerResumeAction) async throws -> NoteContainer {
        fatalError("not scripted")
    }
    func validateNoteContainerPath(path: String, agentSlug: String?) async throws -> NoteContainerPathCheck {
        NoteContainerPathCheck(ok: true, resolvedPath: path, reason: nil, existingNotes: 0)
    }
    func getNoteLinkHealth(containerId: String) async throws -> NoteLinkHealth {
        NoteLinkHealth(broken: [], outside: [], unlinkedAttachments: [], unlinkedNotes: [], ambiguousNames: [])
    }

    func getNoteAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult { .notFound }
    func uploadNoteAttachment(containerId: String, filename: String, mimeType: String, data: Data) async throws
        -> NoteAttachmentUploaded
    { fatalError("not scripted") }
    func listNoteAttachments(containerId: String) async throws -> [NoteAttachmentRecord] { [] }
    func deleteNoteAttachment(containerId: String, path: String) async throws -> Bool { true }
    func renameNoteAttachment(containerId: String, fromPath: String, toPath: String) async throws
        -> NoteAttachmentRecord
    { fatalError("not scripted") }
}

private enum NoteFixture {
    static func summary(id: String, name: String = "Note", pendingDelete: Bool = false) -> NoteSummary {
        NoteSummary(
            id: id, name: name, summary: nil, containerId: nil, favourite: false, tags: [],
            updatedAtMs: 0, pendingDelete: pendingDelete)
    }

    static func detail(id: String, name: String = "Note") -> NoteDetail {
        NoteDetail(
            id: id, name: name, summary: nil, containerId: nil, favourite: false, tags: [],
            updatedAtMs: 0, pendingDelete: false, frontmatter: nil, body: "", contentHash: "h",
            createdAt: nil, createdAtMs: nil, lastWriteSource: nil)
    }
}

@MainActor
final class NotesStoreTests: XCTestCase {

    func testCreateNoteInsertsAtFrontOfIndex() async {
        let api = FakeNotesApi()
        api.createNoteResult = NoteFixture.detail(id: "abc", name: "Untitled")
        api.getNotesResult = [NoteFixture.summary(id: "existing")]
        let store = NotesStore(api: api)
        await store.refresh()

        let created = await store.createNote(name: "Untitled")

        XCTAssertEqual(created?.id, "abc")
        XCTAssertEqual(store.notes.map(\.id), ["abc", "existing"])
        XCTAssertEqual(api.createNoteCalls.count, 1)
    }

    /// The delete confirmation route calls the server immediately and marks the row
    /// `pendingDelete` — it does NOT remove the row, since the undo window still shows it
    /// (dimmed) rather than making it vanish and reappear.
    func testRequestDeleteMarksRowPendingDeleteRatherThanRemovingIt() async {
        let api = FakeNotesApi()
        api.getNotesResult = [NoteFixture.summary(id: "n1")]
        let store = NotesStore(api: api)
        await store.refresh()

        let ok = await store.requestDelete(id: "n1")

        XCTAssertTrue(ok)
        XCTAssertEqual(api.deleteNoteCalls, ["n1"])
        XCTAssertEqual(store.notes.count, 1)
        XCTAssertTrue(store.notes[0].pendingDelete)
    }

    func testRequestDeleteReportsFailureAndLeavesRowUntouchedOnServerError() async {
        struct Boom: Error {}
        let api = FakeNotesApi()
        api.deleteNoteError = Boom()
        api.getNotesResult = [NoteFixture.summary(id: "n1")]
        let store = NotesStore(api: api)
        await store.refresh()

        let ok = await store.requestDelete(id: "n1")

        XCTAssertFalse(ok)
        XCTAssertFalse(store.notes[0].pendingDelete)
        XCTAssertNotNil(store.loadError)
    }

    func testUndeleteRestoresTheRowAndClearsPendingDelete() async {
        let api = FakeNotesApi()
        api.undeleteNoteResult = NoteFixture.detail(id: "n1", name: "Back")
        api.getNotesResult = [NoteFixture.summary(id: "n1", pendingDelete: true)]
        let store = NotesStore(api: api)
        await store.refresh()

        let ok = await store.undelete(id: "n1")

        XCTAssertTrue(ok)
        XCTAssertEqual(api.undeleteNoteCalls, ["n1"])
        XCTAssertFalse(store.notes[0].pendingDelete)
        XCTAssertEqual(store.notes[0].name, "Back")
    }

    func testRenameUpdatesTheLocalRowFromTheServersResponse() async {
        let api = FakeNotesApi()
        api.patchNoteResult = .saved(NoteFixture.detail(id: "n1", name: "New Name"))
        api.getNotesResult = [NoteFixture.summary(id: "n1", name: "Old Name")]
        let store = NotesStore(api: api)
        await store.refresh()

        let ok = await store.rename(id: "n1", name: "New Name")

        XCTAssertTrue(ok)
        XCTAssertEqual(store.notes[0].name, "New Name")
    }

    /// A rename to whitespace-only text must not reach the server at all — the same guard the
    /// session rename sheet applies.
    func testRenameToBlankNameIsRejectedLocally() async {
        let api = FakeNotesApi()
        api.getNotesResult = [NoteFixture.summary(id: "n1", name: "Old Name")]
        let store = NotesStore(api: api)
        await store.refresh()

        let ok = await store.rename(id: "n1", name: "   ")

        XCTAssertFalse(ok)
        XCTAssertTrue(api.patchNoteCalls.isEmpty)
        XCTAssertEqual(store.notes[0].name, "Old Name")
    }

    /// A conflict answer from a rename must not be silently swallowed as success — the caller
    /// has to be told the write did not land.
    func testRenameReturnsFalseOnConflict() async {
        let api = FakeNotesApi()
        api.patchNoteResult = .conflict(NoteConflict(currentHash: "x", updatedAtMs: 0, frontmatter: nil, body: nil))
        api.getNotesResult = [NoteFixture.summary(id: "n1", name: "Old Name")]
        let store = NotesStore(api: api)
        await store.refresh()

        let ok = await store.rename(id: "n1", name: "New Name")

        XCTAssertFalse(ok)
        XCTAssertEqual(store.notes[0].name, "Old Name")
    }

    /// The race the spurious "changed elsewhere" banner was traced to: `loadNote` — fired by the
    /// tools panel refreshing, or the screen re-appearing — can still be in flight when an
    /// autosave completes. Applying the load's answer regardless would roll `details` back to the
    /// pre-save hash, and the *next* autosave would then send that stale hash as its precondition
    /// and be told, correctly, that the note "changed elsewhere" — when the only thing that
    /// happened was its own earlier save. Driven with a gate rather than a sleep, so the ordering
    /// under test is exact rather than hoped-for.
    func testALoadInFlightDuringASaveDoesNotRewindTheBaseline() async {
        let api = FakeNotesApi()
        api.getNotesResult = [NoteFixture.summary(id: "n1")]
        let store = NotesStore(api: api)
        await store.refresh()
        // Seed a baseline the way opening the note would, before the race begins.
        api.getNoteResult = NoteFixture.detail(id: "n1", name: "Before The Edit")
        await store.loadNote(id: "n1")
        XCTAssertEqual(store.detail(for: "n1")?.name, "Before The Edit")

        // A second load starts — the tools panel refreshing while the reader is still typing —
        // and is held right at the point its GET request has gone out.
        api.getNoteGateEnabled = true
        api.getNoteResult = NoteFixture.detail(id: "n1", name: "Stale, from before the save")
        let raceLoad = Task { await store.loadNote(id: "n1") }
        await api.waitUntilGetNoteStarted()

        // The autosave completes entirely while that load is still suspended.
        api.patchNoteResult = .saved(NoteFixture.detail(id: "n1", name: "Saved by the autosave"))
        store.edit(id: "n1", body: "new body")
        await store.flush(id: "n1")
        XCTAssertEqual(store.detail(for: "n1")?.name, "Saved by the autosave")

        // Only now does the stale GET's response land.
        api.releaseGetNote()
        await raceLoad.value

        XCTAssertEqual(
            store.detail(for: "n1")?.name, "Saved by the autosave",
            "a load that started before the save must not roll the baseline back once it returns after it")
    }
}
