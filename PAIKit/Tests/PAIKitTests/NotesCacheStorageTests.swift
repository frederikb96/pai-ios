import XCTest

@testable import PAIKit

/// The file-backed notes cache and note outbox, against a real temp directory. Re-run on the Mac
/// lane as well: the file system is where Linux and Darwin Foundation differ.
final class NotesCacheStorageTests: XCTestCase {
    private var parent: URL!

    override func setUp() {
        super.setUp()
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("notes-cache-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: parent)
        super.tearDown()
    }

    private func detail(id: String, body: String, updatedAtMs: Int = 1) -> NoteDetail {
        NoteDetail(
            id: id, name: "Note", summary: nil, containerId: "c1", favourite: false, tags: [],
            updatedAtMs: updatedAtMs, pendingDelete: false, frontmatter: nil, body: body, contentHash: "h-\(body)",
            createdAt: nil, createdAtMs: nil, lastWriteSource: "ui")
    }

    /// The app keeps the cache and the outbox side by side under one directory. Clearing the
    /// cache is a button in Settings; reaching past its own root would delete edits the server
    /// has never seen.
    func testClearingTheCacheLeavesPendingEditsAlone() {
        let cache = FileNotesCacheStorage(rootURL: parent.appendingPathComponent("NotesCache"))
        let outbox = FileNoteOutboxStorage(rootURL: parent.appendingPathComponent("NoteOutbox"))
        cache.saveBody(detail(id: "n1", body: "server"))
        cache.saveIndex(CachedNoteIndex(notes: []))
        XCTAssertTrue(cache.writeAttachment(Data([1, 2, 3]), fileId: "f1"))
        outbox.saveEdit(
            NotePendingEdit(noteId: "n1", body: "typed offline", base: detail(id: "n1", body: "server"), editedAtMs: 2))

        cache.clear()

        XCTAssertNil(cache.loadBody(noteId: "n1"))
        XCTAssertNil(cache.loadIndex())
        XCTAssertNil(cache.readAttachment(fileId: "f1"))
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["typed offline"])
        // Still usable after a clear: the directories it writes into are back.
        cache.saveBody(detail(id: "n2", body: "after"))
        XCTAssertEqual(cache.loadBody(noteId: "n2")?.body, "after")
    }

    /// Ids come from the server. One carrying a path separator must land inside the cache, and
    /// still be found again under the same id.
    func testAnIdWithPathCharactersStaysInsideItsDirectory() throws {
        let root = parent.appendingPathComponent("NotesCache")
        let cache = FileNotesCacheStorage(rootURL: root)
        cache.saveBody(detail(id: "../../escape", body: "x"))

        XCTAssertEqual(cache.loadBody(noteId: "../../escape")?.body, "x")
        let outside = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        XCTAssertEqual(outside, ["NotesCache"], "nothing may be written next to the cache root")
        XCTAssertEqual(cache.bodyStamps()["../../escape"], 1)
    }

    /// Replacing a body goes through a temp file renamed over the old one: the newest version
    /// wins, and no temp file is left to be counted as cache or read back as a body.
    func testRewritingABodyKeepsOnlyTheNewestVersion() throws {
        let root = parent.appendingPathComponent("NotesCache")
        let cache = FileNotesCacheStorage(rootURL: root)
        cache.saveBody(detail(id: "n1", body: "first", updatedAtMs: 1))
        cache.saveBody(detail(id: "n1", body: "second", updatedAtMs: 2))

        XCTAssertEqual(cache.loadBody(noteId: "n1")?.body, "second")
        XCTAssertEqual(cache.bodyStamps(), ["n1": 2])
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("bodies").path)
        XCTAssertEqual(files, ["n1.json"])
    }

    /// What the budget evicts is attachments; what it counts as fixed cost must not include
    /// them, or every file would be counted twice and the cache would evict far below its budget.
    func testMetadataBytesDoesNotCountAttachmentBlobs() {
        let cache = FileNotesCacheStorage(rootURL: parent.appendingPathComponent("NotesCache"))
        cache.saveBody(detail(id: "n1", body: "short"))
        let before = cache.metadataBytes()
        XCTAssertGreaterThan(before, 0)

        XCTAssertTrue(cache.writeAttachment(Data(count: 1_000_000), fileId: "big"))

        XCTAssertLessThan(cache.metadataBytes(), before + 1_000)
        XCTAssertEqual(cache.readAttachment(fileId: "big")?.count, 1_000_000)
    }

    /// A pending edit read back by a fresh storage — what the app does on its next launch —
    /// carries everything a replay needs: the text, the version it was typed over, and an
    /// unanswered conflict.
    func testAPendingEditSurvivesARelaunchWithItsBaseAndConflict() {
        let root = parent.appendingPathComponent("NoteOutbox")
        let conflict = NoteConflict(currentHash: "theirs", updatedAtMs: 9, frontmatter: nil, body: "their text")
        FileNoteOutboxStorage(rootURL: root).saveEdit(
            NotePendingEdit(
                noteId: "n1", body: "mine", base: detail(id: "n1", body: "base"), editedAtMs: 5,
                raisedConflict: conflict, awaitingSync: true))
        FileNoteOutboxStorage(rootURL: root).saveFieldPatch(
            NotePendingFieldPatch(noteId: "n1", name: "Renamed", editedAtMs: 6))

        let relaunched = FileNoteOutboxStorage(rootURL: root)
        let edits = relaunched.loadEdits()
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.body, "mine")
        XCTAssertEqual(edits.first?.base.contentHash, "h-base")
        XCTAssertEqual(edits.first?.raisedConflict, conflict)
        XCTAssertEqual(edits.first?.awaitingSync, true)
        XCTAssertEqual(relaunched.loadFieldPatches().first?.name, "Renamed")

        relaunched.removeEdit(noteId: "n1")
        XCTAssertTrue(FileNoteOutboxStorage(rootURL: root).loadEdits().isEmpty)
    }
}

final class NotesCacheBudgetTests: XCTestCase {
    private func entry(_ id: String, bytes: Int, usedAt: Int) -> CachedAttachment {
        CachedAttachment(
            fileId: id, containerId: "c", path: "attachments/\(id)", byteCount: bytes, sizeBytes: bytes, mtimeMs: 1,
            lastUsedMs: usedAt)
    }

    func testTheLeastRecentlyUsedFilesGoFirstAndOnlyUntilItFits() {
        let entries = [
            entry("newest", bytes: 400, usedAt: 30),
            entry("oldest", bytes: 400, usedAt: 10),
            entry("middle", bytes: 400, usedAt: 20),
        ]
        // 1,200 bytes of files plus 100 of metadata against a 900-byte budget: one file must go,
        // and it is the one used longest ago.
        XCTAssertEqual(
            NotesCacheBudget.evictions(attachments: entries, metadataBytes: 100, budgetBytes: 900), ["oldest"])
        // Metadata counts too: with 500 bytes of it the second-oldest goes as well.
        XCTAssertEqual(
            NotesCacheBudget.evictions(attachments: entries, metadataBytes: 500, budgetBytes: 900),
            ["oldest", "middle"])
    }

    func testNothingIsEvictedUnderTheBudget() {
        let entries = [entry("a", bytes: 400, usedAt: 1)]
        XCTAssertEqual(NotesCacheBudget.evictions(attachments: entries, metadataBytes: 100, budgetBytes: 500), [])
    }

    func testAFileLargerThanTheBudgetIsNeverStored() {
        XCTAssertFalse(NotesCacheBudget.admits(byteCount: 2_000, budgetBytes: 1_000))
        XCTAssertTrue(NotesCacheBudget.admits(byteCount: 1_000, budgetBytes: 1_000))
    }
}
