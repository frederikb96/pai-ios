import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import PAIKit

/// A notes server with the parts of the real one the offline rules depend on: conditional saves
/// against a content hash, and version history that coalesces per writing side.
///
/// The history rule follows `_snapshot_note_revision` in pai-cloud's `repository.py`: a content
/// write that changes the hash first snapshots the current version, unless the newest snapshot is
/// younger than the coalescing window and came from the same side. That rule is why the phone
/// names its side on every content save (`phone` online, `offline` for an edit that waited); a
/// fake that kept every version could not tell the difference. Like the route, it refuses a
/// `source` outside the ones a REST client may claim.
private final class FakeNotesServer: NotesApiClient, @unchecked Sendable {
    struct Revision: Equatable {
        let body: String
        let source: String
        let createdAtMs: Int
    }

    struct Patch: Equatable {
        let id: String
        let body: String?
        let name: String?
        let favourite: Bool?
        let expectedHash: String?
        let source: String?
    }

    static let coalesceMs = 300_000
    /// `_PATCH_SOURCES` in pai-cloud's `notes_api.py`.
    static let patchSources: Set<String> = ["ui", "phone", "offline"]

    var nowMs = 1_000_000_000
    private(set) var bodies: [String: String] = [:]
    private(set) var hashes: [String: String] = [:]
    private(set) var names: [String: String] = [:]
    private(set) var favourites: [String: Bool] = [:]
    private(set) var revisions: [String: [Revision]] = [:]
    private var writes = 0

    private(set) var patches: [Patch] = []
    private(set) var getNoteCalls: [String] = []
    private(set) var attachmentGets: [String] = []

    /// Every request throws the way `URLSession` does with no network.
    var offline = false
    /// Thrown by the index route alone.
    var indexFailure: Error?
    /// Thrown by the next PATCHes, in order, before anything else happens.
    var patchFailures: [Error] = []
    /// Runs before each PATCH is judged: another writer getting there first.
    var beforePatch: ((FakeNotesServer, String) -> Void)?
    /// Names the server refuses, as it refuses a name already taken in the container.
    var takenNames: Set<String> = []
    var attachments: [String: Data] = [:]
    var inventory: [NoteAttachmentRecord] = []

    /// Holds the next PATCH open until released, so a test can act while it is in flight.
    var holdPatch = false
    /// With `holdPatch`: the write is applied first and only the answer is held — a save the
    /// server has taken whose response has not arrived yet.
    var holdAfterApplying = false
    private let lock = NSLock()
    private var held: CheckedContinuation<Void, Never>?
    private var heldStarted: CheckedContinuation<Void, Never>?
    private var hasHeld = false

    func seed(id: String, name: String = "Note", body: String, favourite: Bool = false) {
        bodies[id] = body
        names[id] = name
        favourites[id] = favourite
        writes += 1
        hashes[id] = "h\(writes)"
    }

    /// Another client (the web) saving the note.
    func write(id: String, body: String, source: String = "ui") {
        snapshot(id: id, source: source)
        bodies[id] = body
        writes += 1
        hashes[id] = "h\(writes)"
    }

    private func snapshot(id: String, source: String) {
        if let newest = revisions[id]?.last, nowMs - newest.createdAtMs < Self.coalesceMs, newest.source == source {
            return
        }
        revisions[id, default: []].append(Revision(body: bodies[id] ?? "", source: source, createdAtMs: nowMs))
    }

    func detail(_ id: String) -> NoteDetail {
        NoteDetail(
            id: id, name: names[id] ?? "Note", summary: nil, containerId: "c1", favourite: favourites[id] ?? false,
            tags: [], updatedAtMs: nowMs, pendingDelete: false, frontmatter: nil, body: bodies[id] ?? "",
            contentHash: hashes[id] ?? "none", createdAt: nil, createdAtMs: nil, lastWriteSource: "ui")
    }

    private func failIfOffline() throws {
        if offline { throw URLError(.notConnectedToInternet) }
    }

    private func hold() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            held = continuation
            hasHeld = true
            let started = heldStarted
            heldStarted = nil
            lock.unlock()
            started?.resume()
        }
    }

    func waitUntilPatchHeld() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasHeld {
                lock.unlock()
                continuation.resume()
            } else {
                heldStarted = continuation
                lock.unlock()
            }
        }
    }

    func releasePatch() {
        lock.lock()
        let release = held
        held = nil
        holdPatch = false
        lock.unlock()
        release?.resume()
    }

    func getNotesConfig() async throws -> NotesConfig { NotesConfig(undoWindowSeconds: 5) }

    func getNotes(containerId: String?, favourite: Bool?, limit: Int, offset: Int) async throws -> [NoteSummary] {
        getNotesCalls += 1
        try failIfOffline()
        if let indexFailure { throw indexFailure }
        return bodies.keys.sorted().map { detail($0).summaryRow }
    }

    /// Holds every note GET this long first, so a test can cancel one in flight.
    var getNoteDelay: Duration?
    private(set) var getNotesCalls = 0
    func getNote(id: String) async throws -> NoteDetail {
        getNoteCalls.append(id)
        if let getNoteDelay { try await Task.sleep(for: getNoteDelay) }
        try failIfOffline()
        guard bodies[id] != nil else { throw PaiError.detail("Note not found", statusCode: 404) }
        return detail(id)
    }

    func patchNote(
        id: String, body: String?, frontmatter: String?, name: String?, summary: String?,
        favourite: Bool?, containerId: String?, expectedHash: String?, source: String?
    ) async throws -> NoteSaveResult {
        patches.append(
            Patch(id: id, body: body, name: name, favourite: favourite, expectedHash: expectedHash, source: source))
        if holdPatch, holdAfterApplying, let body, expectedHash == hashes[id] {
            write(id: id, body: body, source: source ?? "ui")
            await hold()
            return .saved(detail(id))
        }
        if holdPatch {
            await withCheckedContinuation { continuation in
                lock.lock()
                held = continuation
                hasHeld = true
                let started = heldStarted
                heldStarted = nil
                lock.unlock()
                started?.resume()
            }
        }
        try failIfOffline()
        if !patchFailures.isEmpty { throw patchFailures.removeFirst() }
        if let source, !Self.patchSources.contains(source) {
            throw PaiError.detail("source must be 'ui', 'phone' or 'offline'", statusCode: 400)
        }
        guard bodies[id] != nil else { throw PaiError.detail("Note not found", statusCode: 404) }
        beforePatch?(self, id)
        if let name {
            if takenNames.contains(name) {
                throw PaiError.detail("A note named '\(name)' already exists", statusCode: 400)
            }
            names[id] = name
        }
        if let favourite { favourites[id] = favourite }
        if let body {
            if let expectedHash, expectedHash != hashes[id] {
                return .conflict(
                    NoteConflict(currentHash: hashes[id]!, updatedAtMs: nowMs, frontmatter: nil, body: bodies[id]))
            }
            if body != bodies[id] { write(id: id, body: body, source: source ?? "ui") }
        }
        return .saved(detail(id))
    }

    func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail {
        try failIfOffline()
        seed(id: "created", name: name, body: body ?? "")
        return detail("created")
    }
    func deleteNote(id: String) async throws -> Bool {
        try failIfOffline()
        return true
    }
    func undeleteNote(id: String) async throws -> NoteDetail { detail(id) }
    func getNoteLinks(id: String) async throws -> NoteLinkGraph {
        try failIfOffline()
        return NoteLinkGraph(outgoing: [], backlinks: [], extractionSkipped: false)
    }
    func listNoteRevisions(id: String) async throws -> [NoteRevisionSummary] { [] }
    func getNoteRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail {
        throw PaiError.detail("not scripted", statusCode: 404)
    }
    func restoreNoteRevision(noteId: String, revisionId: String) async throws -> NoteDetail {
        write(id: noteId, body: "restored", source: "restore")
        return detail(noteId)
    }
    func searchNotes(q: String, containerId: String?, limit: Int?, window: TimeBounds?) async throws -> NoteSearchPage {
        NoteSearchPage(hits: [], truncated: false)
    }
    func getNoteContainers() async throws -> [NoteContainer] { [] }
    func createNoteContainer(path: String, name: String, agentSlug: String?, isDefault: Bool) async throws
        -> NoteContainer
    { throw PaiError.detail("not scripted", statusCode: 404) }
    func patchNoteContainer(id: String, name: String?, enabled: Bool?, isDefault: Bool?) async throws
        -> NoteContainer
    { throw PaiError.detail("not scripted", statusCode: 404) }
    func deleteNoteContainer(id: String) async throws -> Bool { true }
    func resumeNoteContainer(id: String, action: NoteContainerResumeAction) async throws -> NoteContainer {
        throw PaiError.detail("not scripted", statusCode: 404)
    }
    func validateNoteContainerPath(path: String, agentSlug: String?) async throws -> NoteContainerPathCheck {
        NoteContainerPathCheck(ok: true, resolvedPath: path, reason: nil, existingNotes: 0)
    }
    func getNoteLinkHealth(containerId: String) async throws -> NoteLinkHealth {
        NoteLinkHealth(broken: [], outside: [], unlinkedAttachments: [], unlinkedNotes: [], ambiguousNames: [])
    }
    func getNoteAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult {
        attachmentGets.append(path)
        try failIfOffline()
        return attachments[path].map { .ok($0) } ?? .notFound
    }
    func uploadNoteAttachment(containerId: String, filename: String, mimeType: String, data: Data) async throws
        -> NoteAttachmentUploaded
    { throw PaiError.detail("not scripted", statusCode: 404) }
    func listNoteAttachments(containerId: String) async throws -> [NoteAttachmentRecord] {
        try failIfOffline()
        return inventory
    }
    func deleteNoteAttachment(containerId: String, path: String) async throws -> Bool { true }
    func renameNoteAttachment(containerId: String, fromPath: String, toPath: String) async throws
        -> NoteAttachmentRecord
    { throw PaiError.detail("not scripted", statusCode: 404) }
}

@MainActor
final class NotesStoreOfflineTests: XCTestCase {

    private var server: FakeNotesServer!
    private var cache: InMemoryNotesCacheStorage!
    private var outbox: InMemoryNoteOutboxStorage!
    private var notices: [NoteSyncNotice] = []

    override func setUp() async throws {
        server = FakeNotesServer()
        cache = InMemoryNotesCacheStorage()
        outbox = InMemoryNoteOutboxStorage()
        notices = []
    }

    /// A store as the app builds one: over storages that outlive it, so a second store over the
    /// same ones is the app's next launch.
    private func makeStore(retry: Duration = .seconds(3600)) -> NotesStore {
        let store = NotesStore(api: server, cache: cache, outbox: outbox, parkedRetryBaseDelay: retry)
        store.onSyncNotice = { [weak self] in self?.notices.append($0) }
        return store
    }

    /// Waits for `condition` with real sleeps (a yield loop livelocks the Linux runner), up to
    /// `timeout`, and answers whether it came true.
    private func eventually(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock().now + timeout
        while !condition() {
            if ContinuousClock().now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Opened online once (so this phone holds a copy), then the network goes.
    private func openThenGoOffline(_ store: NotesStore, id: String = "n1") async {
        await store.refresh()
        await store.loadNote(id: id)
        server.offline = true
        store.setPathSatisfied(false)
    }

    private func goOnline(_ store: NotesStore) {
        server.offline = false
        store.setPathSatisfied(true)
    }

    // MARK: Reading without a connection

    /// The list opens from this phone's copy, and a failed refresh keeps it on screen.
    func testTheCachedIndexIsShownAtLaunchAndSurvivesAFailedRefresh() async {
        server.seed(id: "n1", name: "Groceries", body: "milk")
        server.seed(id: "n2", name: "Trip", body: "tent")
        await makeStore().refresh()

        server.offline = true
        let relaunched = makeStore()
        XCTAssertEqual(relaunched.notes.map(\.name), ["Groceries", "Trip"], "the index is there before any request")

        await relaunched.refresh()

        XCTAssertEqual(relaunched.notes.map(\.name), ["Groceries", "Trip"])
        XCTAssertTrue(relaunched.isOffline)
    }

    /// A note opened before opens again without a connection, as a note rather than an error; a
    /// note never opened says it is not on this phone.
    func testANoteOpenedBeforeOpensOfflineAndAnUnseenOneSaysSo() async {
        server.seed(id: "n1", body: "kept on the phone")
        server.seed(id: "n2", body: "never opened")
        let first = makeStore()
        await first.refresh()
        await first.loadNote(id: "n1")

        server.offline = true
        let relaunched = makeStore()
        await relaunched.loadNote(id: "n1")
        await relaunched.loadNote(id: "n2")

        XCTAssertEqual(relaunched.body(for: "n1"), "kept on the phone")
        XCTAssertEqual(relaunched.saveState(for: "n1"), .clean)
        XCTAssertFalse(relaunched.unavailableOffline.contains("n1"))
        XCTAssertNil(relaunched.body(for: "n2"))
        XCTAssertTrue(relaunched.unavailableOffline.contains("n2"))
    }

    // MARK: Editing without a connection

    /// With the path down nothing is sent; the edit is on disk, against the version it was typed
    /// over.
    func testAnOfflineEditWaitsOnDiskAgainstItsBase() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        let baseHash = store.detail(for: "n1")?.contentHash

        store.edit(id: "n1", body: "base and offline")
        await store.flush(id: "n1")

        XCTAssertEqual(store.saveState(for: "n1"), .waitingForNetwork)
        XCTAssertTrue(server.patches.isEmpty, "no request while the path is down")
        let stored = outbox.loadEdits()
        XCTAssertEqual(stored.map(\.body), ["base and offline"])
        XCTAssertEqual(stored.first?.base.contentHash, baseHash)
    }

    /// Typing is on disk well inside the autosave debounce, not only at the save: a kill before
    /// the save goes out loses nothing older than the outbox's own short coalescing delay.
    func testAnEditIsOnDiskBeforeTheDebounceFires() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")

        store.edit(id: "n1", body: "typed, then the app was killed")

        let written = await eventually(timeout: NotesStore.autosaveDelay) { !outbox.loadEdits().isEmpty }
        XCTAssertTrue(written, "on disk before the debounce fires")
        let nextLaunch = makeStore()
        XCTAssertEqual(nextLaunch.body(for: "n1"), "typed, then the app was killed")
        XCTAssertTrue(server.patches.isEmpty)
    }

    /// An edit already on its way when the app dies is still on disk for the next launch. The
    /// request is held open while a second store reads the same disk.
    func testAnEditIsOnDiskBeforeItsRequestLeaves() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        server.holdPatch = true

        store.edit(id: "n1", body: "typed just before the kill")
        let save = Task { await store.flush(id: "n1") }
        await server.waitUntilPatchHeld()

        let nextLaunch = makeStore()
        XCTAssertEqual(nextLaunch.body(for: "n1"), "typed just before the kill")
        XCTAssertEqual(nextLaunch.saveState(for: "n1"), .waitingForNetwork)

        server.releasePatch()
        await save.value
        XCTAssertTrue(outbox.loadEdits().isEmpty, "a saved edit leaves the outbox")
    }

    /// The whole round trip: edited offline, the app restarted, back online, sent once with the
    /// base it was typed over and marked as an offline edit.
    func testAnOfflineEditSurvivesARestartAndIsSentWhenTheNetworkReturns() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        let baseHash = store.detail(for: "n1")?.contentHash
        store.edit(id: "n1", body: "offline text")
        await store.flush(id: "n1")

        let relaunched = makeStore()
        goOnline(relaunched)
        await relaunched.resumeSync()

        XCTAssertEqual(server.patches.count, 1)
        XCTAssertEqual(server.patches.first?.expectedHash, baseHash)
        XCTAssertEqual(server.patches.first?.source, NoteWriteSource.offline)
        XCTAssertEqual(server.bodies["n1"], "offline text")
        XCTAssertEqual(relaunched.saveState(for: "n1"), .clean)
        XCTAssertTrue(outbox.loadEdits().isEmpty)
        XCTAssertEqual(relaunched.lastSyncReport?.replayed, 1)
        XCTAssertEqual(notices, [.synced(count: 1)])
    }

    /// A hash that moved outside the body is adopted and written again, exactly as online, still
    /// marked as the offline edit.
    func testAReplayWhoseHashMovedOutsideTheBodyAdoptsItAndSaves() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "base plus")
        await store.flush(id: "n1")
        // The same body under a new hash: a frontmatter-only change on the server.
        server.write(id: "n1", body: "base", source: "disk")

        goOnline(store)
        await store.resumeSync()

        XCTAssertEqual(server.patches.count, 2)
        XCTAssertEqual(server.patches.map(\.source), [NoteWriteSource.offline, NoteWriteSource.offline])
        XCTAssertEqual(server.bodies["n1"], "base plus")
        XCTAssertEqual(store.saveState(for: "n1"), .clean)
        XCTAssertTrue(notices.allSatisfy { if case .overwroteNewerVersion = $0 { false } else { true } })
    }

    /// The policy. The note was edited on the web twice while the phone was offline, the second
    /// time within the server's coalescing window. The phone's edit wins without a question, and
    /// the web's latest text is in the note's history — which holds only because the replay
    /// names its own side: sent as an ordinary save it would coalesce with the web's checkpoint
    /// and the web's text would exist nowhere.
    func testAnOfflineEditWinsAConflictAndTheDisplacedVersionIsKept() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "written on the plane")
        await store.flush(id: "n1")

        server.write(id: "n1", body: "web, first")
        server.nowMs += 60_000
        server.write(id: "n1", body: "web, second")
        server.nowMs += 60_000
        let webHash = server.hashes["n1"]

        goOnline(store)
        await store.resumeSync()

        XCTAssertEqual(server.patches.count, 2, "one conditional save, refused, then one write over")
        XCTAssertEqual(
            server.patches.last?.expectedHash, webHash, "the second write is conditional on what it replaces")
        XCTAssertEqual(server.patches.last?.source, NoteWriteSource.offline)
        XCTAssertEqual(server.bodies["n1"], "written on the plane")
        XCTAssertTrue(
            server.revisions["n1", default: []].contains { $0.body == "web, second" },
            "the version the offline edit replaced must be in the history")
        XCTAssertEqual(store.saveState(for: "n1"), .clean)
        XCTAssertTrue(outbox.loadEdits().isEmpty)
        XCTAssertEqual(notices, [.overwroteNewerVersion(noteId: "n1", name: "Note")])
        XCTAssertEqual(store.lastSyncReport?.conflictsResolved, 1)
    }

    /// A note that keeps moving under the replay stops after a few tries and waits, with the
    /// edit still on screen and on disk.
    func testAConflictThatKeepsComingBackLeavesTheEditWaiting() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        var round = 0
        server.beforePatch = { server, id in
            round += 1
            server.write(id: id, body: "someone else, round \(round)")
        }

        goOnline(store)
        await store.resumeSync()

        XCTAssertEqual(store.saveState(for: "n1"), .waitingForNetwork)
        XCTAssertEqual(store.body(for: "n1"), "mine")
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["mine"])
        XCTAssertLessThanOrEqual(server.patches.count, 1 + NotesStore.offlineConflictAttempts, "bounded")
    }

    /// The connection dropping again during the replay leaves the edit where it was.
    func testATransportFailureDuringTheReplayLeavesTheEditWaiting() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")

        goOnline(store)
        server.patchFailures = [URLError(.networkConnectionLost)]
        await store.resumeSync()

        XCTAssertEqual(store.saveState(for: "n1"), .waitingForNetwork)
        XCTAssertTrue(store.isOffline)
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["mine"])
    }

    /// A server error is a reason to wait, not to fail.
    func testAServerErrorParksTheEditInsteadOfFailingIt() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        server.patchFailures = [PaiError.detail("busy", statusCode: 503)]

        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")

        XCTAssertEqual(store.saveState(for: "n1"), .waitingForNetwork)
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["mine"])
        XCTAssertFalse(store.isOffline, "a 503 is an answer: the network is up")
    }

    /// A note deleted elsewhere cannot take the edit; the text stays on this phone.
    func testANoteDeletedElsewhereFailsTheReplayAndKeepsTheText() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        server.patchFailures = [PaiError.detail("Note not found", statusCode: 404)]

        goOnline(store)
        await store.resumeSync()

        guard case .failed = store.saveState(for: "n1") else {
            return XCTFail("expected a failure the reader can see, got \(store.saveState(for: "n1"))")
        }
        XCTAssertEqual(store.body(for: "n1"), "mine")
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["mine"])
    }

    // MARK: Renames offline

    func testAnOfflineRenameShowsAtOnceAndIsSentLater() async {
        server.seed(id: "n1", name: "Old", body: "x")
        let store = makeStore()
        await openThenGoOffline(store)

        let accepted = await store.rename(id: "n1", name: "New")

        XCTAssertTrue(accepted)
        XCTAssertEqual(store.notes.first?.name, "New")
        XCTAssertEqual(store.name(for: "n1"), "New")
        XCTAssertTrue(server.patches.isEmpty)

        // An index fetch landing before the rename is sent still says "Old"; it must not put
        // that back over the queued name.
        goOnline(store)
        await store.refresh()
        XCTAssertEqual(store.notes.first?.name, "New")
        XCTAssertTrue(server.patches.isEmpty)

        await store.resumeSync()
        XCTAssertEqual(server.names["n1"], "New")
        XCTAssertTrue(store.pendingFieldPatches.isEmpty)
        XCTAssertTrue(outbox.loadFieldPatches().isEmpty)
        XCTAssertEqual(store.notes.first?.name, "New")
    }

    func testAnOfflineRenameTheServerRefusesIsRevertedWithANotice() async {
        server.seed(id: "n1", name: "Old", body: "x")
        server.takenNames = ["Taken"]
        let store = makeStore()
        await openThenGoOffline(store)
        await store.rename(id: "n1", name: "Taken")

        goOnline(store)
        // The index fetch that ends a sync would put the server's name back by itself; with it
        // failing, the revert has to come from the refusal.
        server.indexFailure = PaiError.detail("busy", statusCode: 503)
        await store.resumeSync()

        XCTAssertEqual(store.notes.first?.name, "Old")
        XCTAssertEqual(store.name(for: "n1"), "Old")
        XCTAssertTrue(store.pendingFieldPatches.isEmpty)
        guard case .renameRefused(let id, let attempted, _) = notices.first else {
            return XCTFail("expected a notice for the refused rename, got \(notices)")
        }
        XCTAssertEqual(id, "n1")
        XCTAssertEqual(attempted, "Taken")
    }

    // MARK: Online behaviour that must not move

    /// The regression guard for online saving: a genuine conflict met by an ordinary save still
    /// raises the banner after exactly one request, and every ordinary save names the phone as its
    /// side, never the offline policy's.
    func testAnOnlineConflictStillRaisesTheBannerAndSavesAsThePhone() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "first save")
        await store.flush(id: "n1")
        server.write(id: "n1", body: "someone else")

        store.edit(id: "n1", body: "first save, then mine")
        await store.flush(id: "n1")

        guard case .conflict = store.saveState(for: "n1") else {
            return XCTFail("an online conflict must reach the reader, got \(store.saveState(for: "n1"))")
        }
        XCTAssertEqual(server.patches.count, 2)
        XCTAssertEqual(server.patches.map(\.source), [NoteWriteSource.phone, NoteWriteSource.phone])
        XCTAssertEqual(server.bodies["n1"], "someone else", "nothing was written over")
        XCTAssertTrue(notices.isEmpty)
        XCTAssertNotNil(
            outbox.loadEdits().first?.raisedConflict, "an unanswered conflict is asked again after a relaunch")
    }

    /// A reload landing on an unsaved edit whose server body moved raises the banner and leaves
    /// the baseline where the edit started. Adopting the new baseline would let the next autosave
    /// pass the hash check and overwrite the other writer's text without a word.
    func testAReloadOverAnUnsavedEditWithAMovedBodyRaisesTheBanner() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        let baseHash = store.detail(for: "n1")?.contentHash
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base, theirs")

        await store.loadNote(id: "n1")

        guard case .conflict(let conflict) = store.saveState(for: "n1") else {
            return XCTFail("expected the banner, got \(store.saveState(for: "n1"))")
        }
        XCTAssertEqual(conflict.body, "base, theirs")
        XCTAssertEqual(store.detail(for: "n1")?.contentHash, baseHash, "the baseline stays where the edit started")
        XCTAssertEqual(store.body(for: "n1"), "base, mine")
        await store.flush(id: "n1")
        XCTAssertTrue(server.patches.isEmpty, "a raised conflict is a question, not a save")
    }

    /// The other two answers of the same rule: a body unchanged under the edit is adopted as the
    /// new baseline, and a body already holding the edit ends it.
    func testAReloadOverAnUnsavedEditAdoptsAnUnmovedBodyAndRecognisesItsOwn() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base", source: "disk")
        let movedHash = server.hashes["n1"]

        await store.loadNote(id: "n1")
        XCTAssertEqual(store.saveState(for: "n1"), .dirty)
        XCTAssertEqual(store.detail(for: "n1")?.contentHash, movedHash)

        server.write(id: "n1", body: "base, mine")
        await store.loadNote(id: "n1")
        XCTAssertEqual(store.saveState(for: "n1"), .clean)
        XCTAssertNil(store.drafts["n1"])
        XCTAssertTrue(outbox.loadEdits().isEmpty)
    }

    /// A reload answered while a save is out can describe the server holding that save already.
    /// Read against the draft, which has moved on with further typing, it would look like someone
    /// else's text and raise the banner against this client's own write; it is dropped instead.
    func testAReloadDuringASaveCannotRaiseTheBannerAgainstThatSave() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        server.holdPatch = true
        server.holdAfterApplying = true

        store.edit(id: "n1", body: "base 1")
        let save = Task { await store.flush(id: "n1") }
        await server.waitUntilPatchHeld()
        store.edit(id: "n1", body: "base 1 2")
        await store.loadNote(id: "n1")

        if case .conflict = store.saveState(for: "n1") {
            XCTFail("a conflict was raised against this client's own save")
        }
        server.releasePatch()
        await save.value
        await store.flush(id: "n1")
        XCTAssertEqual(server.bodies["n1"], "base 1 2")
        XCTAssertEqual(store.saveState(for: "n1"), .clean)
    }

    /// Opening a note with an edit waiting sends the edit; it does not move the baseline under it.
    func testOpeningANoteWithAnEditWaitingSendsTheEditInsteadOfReloading() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        server.write(id: "n1", body: "theirs")
        let getsBefore = server.getNoteCalls.count

        goOnline(store)
        await store.loadNote(id: "n1")

        XCTAssertEqual(server.getNoteCalls.count, getsBefore, "no reload over a waiting edit")
        XCTAssertEqual(server.patches.first?.source, NoteWriteSource.offline)
        XCTAssertEqual(server.bodies["n1"], "mine")
        XCTAssertTrue(server.revisions["n1", default: []].contains { $0.body == "theirs" })
    }

    // MARK: The outbox against every way a draft ends

    /// Answering a conflict with the server's version, or restoring an old version, discards the
    /// draft on purpose. It must leave the disk too, or the next launch would replay it over the
    /// version the reader chose.
    func testDiscardingADraftOnPurposeRemovesItFromDisk() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base, theirs")
        await store.flush(id: "n1")
        XCTAssertEqual(outbox.loadEdits().count, 1)

        await store.resolveConflict(id: "n1", keeping: .theirs)
        XCTAssertTrue(outbox.loadEdits().isEmpty, "choosing the server's version ends the edit")

        store.edit(id: "n1", body: "typed again")
        let written = await eventually { outbox.loadEdits().count == 1 }
        XCTAssertTrue(written)
        await store.restoreRevision(noteId: "n1", revisionId: "r1")
        XCTAssertTrue(outbox.loadEdits().isEmpty, "restoring a version ends the edit")
    }

    // MARK: Attachments and the budget

    private func record(_ path: String, size: Int, mtime: Int) -> NoteAttachmentRecord {
        NoteAttachmentRecord(relPath: path, basename: path, ext: "png", sizeBytes: size, mtimeMs: mtime, linkCount: 1)
    }

    /// A file fetched once is served from disk on a later launch while the inventory says it is
    /// unchanged, fetched again when it changed, and served from disk with no connection.
    func testAFetchedFileIsServedFromDiskUntilTheInventorySaysItChanged() async throws {
        server.attachments["a.png"] = Data([1, 2, 3])
        server.inventory = [record("a.png", size: 3, mtime: 10)]
        let first = makeStore()
        _ = try await first.listAttachments(containerId: "c1")
        _ = try await first.fetchAttachment(containerId: "c1", path: "a.png")
        await first.persistManifestAndEvict()
        XCTAssertEqual(server.attachmentGets.count, 1)

        let unchanged = makeStore()
        _ = try await unchanged.listAttachments(containerId: "c1")
        let served = try await unchanged.fetchAttachment(containerId: "c1", path: "a.png")
        guard case .ok(let data) = served else { return XCTFail("expected the file") }
        XCTAssertEqual(data, Data([1, 2, 3]))
        XCTAssertEqual(server.attachmentGets.count, 1, "unchanged on the server: no request")

        server.attachments["a.png"] = Data([4, 5, 6, 7])
        server.inventory = [record("a.png", size: 4, mtime: 20)]
        let changed = makeStore()
        _ = try await changed.listAttachments(containerId: "c1")
        let refreshed = try await changed.fetchAttachment(containerId: "c1", path: "a.png")
        guard case .ok(let newer) = refreshed else { return XCTFail("expected the file") }
        XCTAssertEqual(newer, Data([4, 5, 6, 7]))
        XCTAssertEqual(server.attachmentGets.count, 2)

        server.offline = true
        let offline = makeStore()
        offline.setPathSatisfied(false)
        let records = try await offline.listAttachments(containerId: "c1")
        XCTAssertEqual(records.first?.sizeBytes, 4, "the inventory is on disk too")
        let fromDisk = try await offline.fetchAttachment(containerId: "c1", path: "a.png")
        guard case .ok(let kept) = fromDisk else { return XCTFail("expected the file from disk") }
        XCTAssertEqual(kept, Data([4, 5, 6, 7]))
    }

    /// Files are evicted down to the budget, oldest first; an edit waiting to sync is not
    /// something the budget or a clear can reach.
    func testEvictionStaysUnderTheBudgetAndNeverTouchesAWaitingEdit() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "offline text")
        await store.flush(id: "n1")
        goOnline(store)
        server.offline = false
        store.setCacheBudget(cache.metadataBytes() + 2_500)

        for name in ["a", "b", "c"] {
            server.attachments[name] = Data(repeating: 1, count: 1_000)
            server.nowMs += 1
            _ = try await store.fetchAttachment(containerId: "c1", path: name)
        }
        await store.persistManifestAndEvict()

        let status = await store.cacheStatus()
        XCTAssertLessThanOrEqual(status.cacheBytes, status.budgetBytes)
        XCTAssertEqual(status.cachedAttachmentCount, 2)
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["offline text"])

        await store.clearCache()
        XCTAssertEqual(outbox.loadEdits().map(\.body), ["offline text"])
        XCTAssertEqual(store.body(for: "n1"), "offline text")
    }

    // MARK: Online-only operations

    /// Creating, deleting and the tools panel's server lists say they need a connection instead
    /// of passing on a transport error nobody can act on.
    func testOnlineOnlyOperationsSayTheyNeedAConnection() async {
        server.seed(id: "n1", body: "x")
        let store = makeStore()
        await openThenGoOffline(store)

        let created = await store.createNote(name: "New")
        XCTAssertNil(created)
        XCTAssertEqual(store.loadError, NoteOnlineOnly.createNote.message)

        let deleted = await store.requestDelete(id: "n1")
        XCTAssertFalse(deleted)
        XCTAssertEqual(store.loadError, NoteOnlineOnly.deleteNote.message)
        XCTAssertFalse(store.notes.contains { $0.pendingDelete })

        await store.loadLinkGraph(id: "n1")
        XCTAssertEqual(store.linkGraphErrors["n1"], NoteOnlineOnly.links.message)
        XCTAssertTrue(store.isOffline)
    }

    // MARK: Search

    func testSemanticSearchWithoutAConnectionSaysItNeedsOne() async {
        let store = NoteMeaningSearchStore(debounceNanos: 0) { _, _ in throw URLError(.notConnectedToInternet) }
        store.update(query: "tents", window: nil)
        let deadline = ContinuousClock().now + .seconds(5)
        while store.phase == .searching, ContinuousClock().now < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(store.phase, .failed(NoteOnlineOnly.semanticSearch.message))
    }

    // MARK: Which side a save names

    /// The banner's "keep mine" right after the web saved twice inside the server's coalescing
    /// window. Sent as the web's own side it would fold into the web's checkpoint and the web's
    /// latest text would exist nowhere; as the phone's side the server keeps it. ("web, first"
    /// was already folded away by the web's own burst, before the phone said anything.)
    func testKeepingMineAfterAWebBurstKeepsTheWebsLatestTextInHistory() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        server.write(id: "n1", body: "web, first")
        server.nowMs += 60_000
        server.write(id: "n1", body: "web, second")
        server.nowMs += 60_000
        store.edit(id: "n1", body: "base, phone")
        await store.flush(id: "n1")
        guard case .conflict = store.saveState(for: "n1") else {
            return XCTFail("expected the banner, got \(store.saveState(for: "n1"))")
        }

        await store.resolveConflict(id: "n1", keeping: .mine)

        XCTAssertEqual(server.bodies["n1"], "base, phone")
        XCTAssertEqual(server.patches.last?.source, NoteWriteSource.phone)
        XCTAssertTrue(
            server.revisions["n1", default: []].contains { $0.body == "web, second" },
            "the web's latest text must be in the history")
    }

    // MARK: Field answers under an unsaved edit

    /// An online rename, favourite or summary answers with the whole note, holding whatever body
    /// the server has now. Over an unsaved edit only the field moves: the next save is still
    /// conditional on the version the edit was typed over, so the other writer's text raises the
    /// banner instead of being overwritten.
    private func assertAFieldAnswerKeepsTheEditsBaseline(
        _ change: (NotesStore) async -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async {
        server.seed(id: "n1", name: "Old", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        let baseHash = store.detail(for: "n1")?.contentHash
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base, theirs")

        await change(store)

        XCTAssertEqual(
            store.detail(for: "n1")?.contentHash, baseHash, "the edit's baseline moved", file: file, line: line)
        XCTAssertEqual(
            outbox.loadEdits().first?.base.contentHash, baseHash, "disk and memory disagree on the baseline",
            file: file, line: line)
        await store.flush(id: "n1")
        XCTAssertEqual(server.patches.last?.expectedHash, baseHash, file: file, line: line)
        XCTAssertEqual(
            server.bodies["n1"], "base, theirs", "the other writer's text was overwritten", file: file, line: line)
        guard case .conflict = store.saveState(for: "n1") else {
            return XCTFail("expected the banner, got \(store.saveState(for: "n1"))", file: file, line: line)
        }
    }

    func testAnOnlineRenameUnderAnUnsavedEditMovesTheNameButNotTheBaseline() async {
        await assertAFieldAnswerKeepsTheEditsBaseline { store in
            let renamed = await store.rename(id: "n1", name: "New")
            XCTAssertTrue(renamed)
            XCTAssertEqual(store.name(for: "n1"), "New")
        }
    }

    func testAnOnlineFavouriteUnderAnUnsavedEditKeepsTheBaseline() async {
        await assertAFieldAnswerKeepsTheEditsBaseline { store in
            await store.setFavourite(id: "n1", favourite: true)
            XCTAssertEqual(store.detail(for: "n1")?.favourite, true)
        }
    }

    func testAnOnlineSummaryUnderAnUnsavedEditKeepsTheBaseline() async {
        await assertAFieldAnswerKeepsTheEditsBaseline { store in
            let saved = await store.updateSummary(id: "n1", summary: "short")
            XCTAssertTrue(saved)
        }
    }

    /// The same rule for a rename sent by the sync: its answer lands while the note's body edit
    /// is still waiting (the server could not take it), and must not become that edit's baseline.
    func testAReplayedRenameNeverMovesTheBaselineUnderAWaitingEdit() async {
        server.seed(id: "n1", name: "Old", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        let baseHash = store.detail(for: "n1")?.contentHash
        store.edit(id: "n1", body: "base, mine")
        await store.flush(id: "n1")
        await store.rename(id: "n1", name: "New")
        server.write(id: "n1", body: "base, theirs")

        goOnline(store)
        server.patchFailures = [PaiError.detail("busy", statusCode: 503)]
        await store.resumeSync()

        XCTAssertEqual(server.names["n1"], "New", "the rename went out")
        XCTAssertEqual(store.saveState(for: "n1"), .waitingForNetwork)
        XCTAssertEqual(store.detail(for: "n1")?.contentHash, baseHash)
        XCTAssertEqual(store.name(for: "n1"), "New")
        XCTAssertEqual(outbox.loadEdits().first?.base.contentHash, baseHash)
    }

    // MARK: Cancelled requests and the offline flag

    /// The editor's `.task { loadNote }` is cancelled when the reader leaves before the answer. A
    /// cancelled request is not a lost connection.
    func testACancelledLoadLeavesTheStoreOnline() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        store.setPathSatisfied(true)
        server.getNoteDelay = .seconds(5)

        let load = Task { await store.loadNote(id: "n1") }
        let started = await eventually { server.getNoteCalls.contains("n1") }
        XCTAssertTrue(started)
        load.cancel()
        await load.value

        XCTAssertFalse(store.isOffline, "a cancelled load flipped the store to offline")
        XCTAssertFalse(store.unavailableOffline.contains("n1"))
        XCTAssertEqual(store.saveState(for: "n1"), .clean, "nothing to show for a load nobody waits for")
    }

    func testBothShapesOfCancellationAreNeitherTransportNorAnAnswer() {
        XCTAssertEqual(NoteSyncFailure.classify(CancellationError()), .cancelled)
        XCTAssertEqual(NoteSyncFailure.classify(URLError(.cancelled)), .cancelled)
        XCTAssertEqual(NoteSyncFailure.classify(URLError(.timedOut)), .transport)
    }

    /// One timeout marks the store offline; the next request that gets an answer, of any kind,
    /// clears it, with no word from the path monitor. Without that the banner would stay up for
    /// good after a single dropped request on a network that never went away.
    func testAnyAnsweredRequestClearsTheOfflineStateWithoutAPathEvent() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        store.setPathSatisfied(true)
        server.offline = true
        await store.refresh()
        XCTAssertTrue(store.isOffline)

        server.offline = false
        await store.loadLinkGraph(id: "n1")

        XCTAssertFalse(store.isOffline)
    }

    // MARK: Edits the server refuses

    /// A note deleted elsewhere refuses the waiting edit with a 404. It is sent once and then
    /// left alone: no retry loop, no index fetch per retry, and no retry on the next launch.
    func testARefusedEditIsSentOnceAndNotRetriedByItself() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore(retry: .milliseconds(20))
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        server.patchFailures = Array(repeating: PaiError.detail("Note not found", statusCode: 404), count: 100)
        let indexBefore = server.getNotesCalls

        goOnline(store)
        await store.resumeSync()
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(server.patches.count, 1)
        XCTAssertLessThanOrEqual(server.getNotesCalls - indexBefore, 1, "at most the sync's own closing fetch")
        XCTAssertFalse(store.hasPendingWork)
        XCTAssertEqual(store.lastSyncReport?.stillPending, 0)

        let relaunched = makeStore(retry: .milliseconds(20))
        relaunched.setPathSatisfied(true)
        await relaunched.resumeSync()
        XCTAssertEqual(server.patches.count, 1, "a relaunch does not send a refused edit again")
        guard case .failed = relaunched.saveState(for: "n1") else {
            return XCTFail("the refusal is shown after a relaunch, got \(relaunched.saveState(for: "n1"))")
        }
        XCTAssertEqual(relaunched.keptTexts.map(\.text), ["mine"])
    }

    /// A server that keeps failing with 503 while the index fetch keeps succeeding: the retries
    /// back off. Only the save itself getting through starts the backoff over.
    func testRetriesBackOffWhileOtherRequestsSucceed() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore(retry: .milliseconds(20))
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        server.patchFailures = Array(repeating: PaiError.detail("busy", statusCode: 503), count: 10_000)

        goOnline(store)
        await store.resumeSync()
        try await Task.sleep(for: .seconds(1))
        let patches = server.patches.count
        store.setPathSatisfied(false)

        // 20, 40, 80, 160, 320 ms between tries fit at most seven sends in a second.
        XCTAssertLessThanOrEqual(patches, 8, "the index fetches reset the backoff")
        XCTAssertGreaterThanOrEqual(patches, 2, "it does retry")
    }

    /// The way out of a refused edit. Keeping it (copying the text) leaves it where it is, across
    /// a relaunch; discarding removes it from memory and disk.
    func testARefusedEditIsKeptUntilDiscardedAndDiscardingRemovesItFromDisk() async {
        server.seed(id: "n1", name: "Trip", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        server.patchFailures = [PaiError.detail("Note not found", statusCode: 404)]
        goOnline(store)
        await store.resumeSync()

        let kept = makeStore()
        XCTAssertEqual(kept.keptTexts.map(\.text), ["mine"], "still reachable after a relaunch")
        XCTAssertEqual(kept.keptTexts.first?.title, "Trip")
        guard let text = kept.keptTexts.first else { return XCTFail("nothing kept") }

        kept.discardKeptText(text)

        XCTAssertTrue(kept.keptTexts.isEmpty)
        XCTAssertNil(kept.drafts["n1"])
        XCTAssertEqual(kept.saveState(for: "n1"), .clean)
        XCTAssertTrue(outbox.loadEdits().isEmpty)
        XCTAssertNil(makeStore().drafts["n1"], "gone after the next launch too")
    }

    // MARK: Restoring after the app was killed

    /// An edit typed online, the app killed before the save, the web editing the note meanwhile.
    /// Restored, it is an ordinary save: the conflict raises the banner, as it would have had the
    /// app stayed up, rather than being settled by the offline policy.
    func testARestoredOnlineEditMeetsAWebEditWithTheBanner() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "base, phone")
        let written = await eventually { !outbox.loadEdits().isEmpty }
        XCTAssertTrue(written)
        server.write(id: "n1", body: "base, web")

        let relaunched = makeStore()
        relaunched.setPathSatisfied(true)
        await relaunched.resumeSync()

        guard case .conflict = relaunched.saveState(for: "n1") else {
            return XCTFail("expected the banner, got \(relaunched.saveState(for: "n1"))")
        }
        XCTAssertEqual(server.patches.map(\.source), [NoteWriteSource.phone])
        XCTAssertEqual(server.bodies["n1"], "base, web")
        XCTAssertTrue(notices.isEmpty)
    }

    /// The other side of the same rule: an edit typed with no network at all is an offline edit
    /// even when the app dies before the save would have parked it.
    func testAnEditTypedWithoutANetworkIsRestoredAsAnOfflineEdit() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "base, plane")
        let written = await eventually { !outbox.loadEdits().isEmpty }
        XCTAssertTrue(written)
        server.write(id: "n1", body: "base, web")

        let relaunched = makeStore()
        goOnline(relaunched)
        await relaunched.resumeSync()

        XCTAssertEqual(server.bodies["n1"], "base, plane")
        XCTAssertEqual(server.patches.last?.source, NoteWriteSource.offline)
        XCTAssertTrue(server.revisions["n1", default: []].contains { $0.body == "base, web" })
    }

    /// A conflict raised by a reload (not by a save) is on disk at once, so a kill right after
    /// still asks the reader at the next launch.
    func testAConflictRaisedByAReloadIsAskedAgainAfterAKill() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base, theirs")
        await store.loadNote(id: "n1")
        guard case .conflict = store.saveState(for: "n1") else { return XCTFail("expected the banner") }

        let relaunched = makeStore()

        guard case .conflict = relaunched.saveState(for: "n1") else {
            return XCTFail("the relaunch did not ask again, got \(relaunched.saveState(for: "n1"))")
        }
    }

    /// A conflict on disk is asked again at launch and never answered by the sync on its own.
    func testAPersistedConflictRaisesTheBannerAtLaunchAndSendsNothing() async {
        server.seed(id: "n1", body: "base")
        let base = server.detail("n1")
        server.write(id: "n1", body: "theirs")
        outbox.saveEdit(
            NotePendingEdit(
                noteId: "n1", body: "mine", base: base, editedAtMs: 1,
                raisedConflict: NoteConflict(
                    currentHash: server.hashes["n1"]!, updatedAtMs: 1, frontmatter: nil, body: "theirs")))

        let store = makeStore()
        store.setPathSatisfied(true)
        await store.resumeSync()

        guard case .conflict = store.saveState(for: "n1") else {
            return XCTFail("expected the banner, got \(store.saveState(for: "n1"))")
        }
        XCTAssertTrue(server.patches.isEmpty)
        XCTAssertEqual(server.bodies["n1"], "theirs")
    }

    // MARK: Replay order

    /// Bodies go before renames, so a rename's link rewrite on the server lands on bodies that
    /// already hold this phone's edits.
    func testWaitingBodiesAreSentBeforeQueuedRenames() async {
        for id in ["n1", "n2", "n3", "n4"] { server.seed(id: id, name: "Note \(id)", body: "base \(id)") }
        let store = makeStore()
        await store.refresh()
        for id in ["n1", "n2", "n3", "n4"] { await store.loadNote(id: id) }
        server.offline = true
        store.setPathSatisfied(false)
        await store.rename(id: "n3", name: "Renamed 3")
        store.edit(id: "n1", body: "base n1, edited")
        await store.flush(id: "n1")
        await store.rename(id: "n4", name: "Renamed 4")
        store.edit(id: "n2", body: "base n2, edited")
        await store.flush(id: "n2")

        goOnline(store)
        await store.resumeSync()

        XCTAssertEqual(
            server.patches.map { $0.body != nil ? "body" : "name" }, ["body", "body", "name", "name"])
    }

    /// Opening a note with both a waiting body and a queued rename sends them in the same order.
    func testOpeningANoteSendsItsBodyBeforeItsRename() async {
        server.seed(id: "n1", name: "Old", body: "base")
        let store = makeStore()
        await openThenGoOffline(store)
        await store.rename(id: "n1", name: "New")
        store.edit(id: "n1", body: "base, edited")
        await store.flush(id: "n1")

        goOnline(store)
        await store.loadNote(id: "n1")

        XCTAssertEqual(server.patches.map { $0.body != nil ? "body" : "name" }, ["body", "name"])
    }

    // MARK: Writing the outbox while typing

    /// A burst of keystrokes is one write once typing pauses, not one write per keystroke.
    func testABurstOfKeystrokesIsWrittenOnce() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        let before = outbox.editWrites

        var text = "base"
        for _ in 0..<50 {
            text += "x"
            store.edit(id: "n1", body: text)
        }
        let written = await eventually { outbox.loadEdits().first?.body == text }

        XCTAssertTrue(written)
        XCTAssertLessThanOrEqual(outbox.editWrites - before, 2)
    }

    /// A keystroke's deferred write never lands after the save that ended the edit: the saved
    /// edit stays gone from disk, so the next launch cannot replay text the server already has.
    func testADeferredWriteNeverBringsBackASavedEdit() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")

        store.edit(id: "n1", body: "base, saved at once")
        await store.flush(id: "n1")
        XCTAssertEqual(store.saveState(for: "n1"), .clean)
        try await Task.sleep(for: NotesStore.outboxWriteDelay * 3)

        XCTAssertTrue(outbox.loadEdits().isEmpty)
    }

    /// Typing over a conflict and then taking the server's version ends the edit with no save in
    /// between. The keystroke's deferred write must not land afterwards and bring the dropped
    /// text back for the next launch to replay.
    func testADeferredWriteNeverBringsBackADiscardedEdit() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base, theirs")
        await store.flush(id: "n1")
        guard case .conflict = store.saveState(for: "n1") else { return XCTFail("expected the banner") }

        store.edit(id: "n1", body: "base, mine, typed over the banner")
        await store.resolveConflict(id: "n1", keeping: .theirs)
        try await Task.sleep(for: NotesStore.outboxWriteDelay * 3)

        XCTAssertTrue(outbox.loadEdits().isEmpty)
        XCTAssertNil(makeStore().drafts["n1"])
    }

    /// A keystroke's deferred write is older than the conflict a reload raises right after it. It
    /// must not land on top and erase the conflict from disk.
    func testADeferredWriteNeverOverwritesANewerRecord() async throws {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.edit(id: "n1", body: "base, mine")
        server.write(id: "n1", body: "base, theirs")
        await store.loadNote(id: "n1")
        guard case .conflict = store.saveState(for: "n1") else { return XCTFail("expected the banner") }
        try await Task.sleep(for: NotesStore.outboxWriteDelay * 3)

        XCTAssertNotNil(outbox.loadEdits().first?.raisedConflict)
    }

    // MARK: Notices

    /// An edit typed online that waited because the server answered 503 is not called an offline
    /// edit when it finally goes through.
    func testAnEditThatWaitedForTheServerIsNotCalledAnOfflineEdit() async {
        server.seed(id: "n1", body: "base")
        let store = makeStore()
        await store.refresh()
        await store.loadNote(id: "n1")
        store.setPathSatisfied(true)
        server.patchFailures = [PaiError.detail("busy", statusCode: 503)]
        store.edit(id: "n1", body: "mine")
        await store.flush(id: "n1")
        XCTAssertEqual(store.saveState(for: "n1"), .waitingForNetwork)

        await store.resumeSync()

        XCTAssertEqual(notices, [.synced(count: 1, madeOffline: false)])
        XCTAssertFalse(notices.first?.message.contains("offline") ?? true)
    }

    // MARK: Clearing and sweeping the cache

    /// Clearing the cache keeps the list rows of notes with something waiting, so without a
    /// connection after a relaunch they are still on the list and their edits reachable.
    func testClearingTheCacheKeepsTheRowsOfNotesWithSomethingWaiting() async {
        server.seed(id: "n1", name: "Waiting", body: "base")
        server.seed(id: "n2", name: "Plain", body: "other")
        let store = makeStore()
        await openThenGoOffline(store)
        store.edit(id: "n1", body: "offline text")
        await store.flush(id: "n1")

        await store.clearCache()
        let relaunched = makeStore()
        relaunched.setPathSatisfied(false)

        XCTAssertEqual(relaunched.notes.map(\.name), ["Waiting"])
        XCTAssertEqual(relaunched.body(for: "n1"), "offline text")
    }

    /// A file written just before the app died, with no manifest entry naming it, is removed at
    /// the next launch; a listed one stays.
    func testAnAttachmentFileTheManifestDoesNotNameIsRemovedAtLaunch() async throws {
        server.attachments["a.png"] = Data([1, 2, 3])
        let first = makeStore()
        _ = try await first.fetchAttachment(containerId: "c1", path: "a.png")
        await first.persistManifestAndEvict()
        XCTAssertTrue(cache.writeAttachment(Data([9]), fileId: "unlisted"))
        XCTAssertEqual(cache.attachmentFileIds().count, 2)

        _ = makeStore()

        XCTAssertEqual(cache.attachmentFileIds().count, 1)
        XCTAssertFalse(cache.attachmentFileIds().contains("unlisted"))
    }
}
