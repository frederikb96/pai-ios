import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol NotesApiClient: Sendable {
    func getNotesConfig() async throws -> NotesConfig
    func getNotes(containerId: String?, favourite: Bool?, limit: Int, offset: Int) async throws -> [NoteSummary]
    func getNote(id: String) async throws -> NoteDetail
    func patchNote(
        id: String, body: String?, frontmatter: String?, name: String?, summary: String?,
        favourite: Bool?, containerId: String?, expectedHash: String?, source: String?
    ) async throws -> NoteSaveResult
    func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail
    func deleteNote(id: String) async throws -> Bool
    func undeleteNote(id: String) async throws -> NoteDetail
    func getNoteLinks(id: String) async throws -> NoteLinkGraph
    func listNoteRevisions(id: String) async throws -> [NoteRevisionSummary]
    func getNoteRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail
    func restoreNoteRevision(noteId: String, revisionId: String) async throws -> NoteDetail
    func searchNotes(q: String, containerId: String?, limit: Int?, window: TimeBounds?) async throws -> NoteSearchPage

    func getNoteContainers() async throws -> [NoteContainer]
    func createNoteContainer(path: String, name: String, agentSlug: String?, isDefault: Bool) async throws
        -> NoteContainer
    func patchNoteContainer(id: String, name: String?, enabled: Bool?, isDefault: Bool?) async throws
        -> NoteContainer
    func deleteNoteContainer(id: String) async throws -> Bool
    func resumeNoteContainer(id: String, action: NoteContainerResumeAction) async throws -> NoteContainer
    func validateNoteContainerPath(path: String, agentSlug: String?) async throws -> NoteContainerPathCheck
    func getNoteLinkHealth(containerId: String) async throws -> NoteLinkHealth

    func getNoteAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult
    func uploadNoteAttachment(containerId: String, filename: String, mimeType: String, data: Data) async throws
        -> NoteAttachmentUploaded
    func listNoteAttachments(containerId: String) async throws -> [NoteAttachmentRecord]
    func deleteNoteAttachment(containerId: String, path: String) async throws -> Bool
    func renameNoteAttachment(containerId: String, fromPath: String, toPath: String) async throws
        -> NoteAttachmentRecord
}

extension PaiApiClient: NotesApiClient {}

/// Where one note's editing session stands. Rendered directly, so the cases are the states a
/// reader can distinguish rather than the states the code passes through.
public enum NoteSaveState: Equatable, Sendable {
    /// Nothing unsaved, as far as this device knows.
    case clean
    /// Typed since the last save; the debounce has not fired yet.
    case dirty
    case saving
    /// The vault moved on under the edit. Both versions exist and the reader has to choose —
    /// see ``NotesStore/resolveConflict(id:keeping:)``.
    case conflict(NoteConflict)
    /// The save failed for a reason that is not a conflict. The edit is still held on this
    /// phone, so the recovery is to try again rather than to retype.
    case failed(String)
    /// The edit is kept on this phone and goes to the server once a request can reach it: no
    /// network, or a server that could not take it just now.
    case waitingForNetwork
}

/// Which side of a conflict to keep.
public enum NoteConflictResolution: Equatable, Sendable {
    /// Overwrite the vault with what is on screen.
    case mine
    /// Discard the local edit and adopt what the vault holds.
    case theirs
}

/// The notes index, the notes currently open, and what is unsaved in each.
///
/// One store rather than one per open note: a note is reachable from the list, from a deep link
/// and from a wikilink in another note, so "is this note dirty" must have one answer wherever it
/// is asked. Per-editor state would let a note be open twice with two divergent bodies and no
/// rule for which one saves last.
///
/// Autosave lives here rather than in the editor view for the same reason plus one more: a save
/// has to survive the editor going away, and a view's task is cancelled the moment it does.
@MainActor
@Observable
public final class NotesStore {

    // MARK: Index

    public internal(set) var notes: [NoteSummary] = []
    public private(set) var containers: [NoteContainer] = []
    public private(set) var loadError: String?
    public private(set) var isLoading = false

    /// Used only until `GET /api/notes/config` answers (``refresh()`` fetches it alongside the
    /// index), and picked to be safely SHORT rather than a guess at the real number: the
    /// backend's own finalize delay is always the undo window plus a margin, so sitting on a
    /// value below the real window merely hides the undo action a little early — harmless —
    /// while a value above it is what lets a press of Undo 404 against a note the backend
    /// already finalized.
    public static let fallbackUndoWindowNanos: UInt64 = 5_000_000_000
    /// How long a delete's undo toast should stay offered — see
    /// ``fallbackUndoWindowNanos``'s own doc comment for why a not-yet-loaded or failed fetch
    /// never leaves this above that short, safe default.
    public private(set) var undoWindowNanos: UInt64 = NotesStore.fallbackUndoWindowNanos

    // MARK: Open notes

    /// The last content read from the server, per note id. What a save is conditional against.
    public internal(set) var details: [String: NoteDetail] = [:]
    /// Bumped every time ``details`` is written for a note, by any of `loadNote`, `saveNow` or
    /// `resolveConflict`. A `loadNote` in flight captures this before its request goes out and
    /// checks it again before applying the response — if a save landed in between, the load's
    /// answer describes a note that no longer exists and is dropped rather than rolling the
    /// baseline back to a hash the next autosave would send as a now-stale precondition.
    var detailVersion: [String: Int] = [:]
    /// The body as it currently stands on screen, for a note edited since it was loaded.
    public internal(set) var drafts: [String: String] = [:]
    public internal(set) var saveStates: [String: NoteSaveState] = [:]
    /// Bumped when a note's body changed for a reason other than local typing: a fresh read, a
    /// conflict answered in the vault's favour, a restored revision.
    ///
    /// The editor rebuilds itself from this rather than from the body, and the difference is the
    /// caret. A save's own response also replaces ``details``, and a backend that normalises
    /// anything at all — a trailing newline, a line ending — then hands back a body that differs
    /// from what is on screen. Watching the body would read that as an external change and
    /// rebuild the editor under the reader a second after they stopped typing.
    public private(set) var externalBodyRevision: [String: Int] = [:]

    // MARK: The link index, per note — a snapshot rather than something kept live, matching the
    // web's own choice (`RightPanel.tsx`): cutting and pasting a link around should not disturb
    // this list while the user types, so it only ever refreshes on an explicit reload.

    public private(set) var linkGraphs: [String: NoteLinkGraph] = [:]
    public private(set) var linkGraphErrors: [String: String] = [:]

    // MARK: Revision history, per note

    public private(set) var revisions: [String: [NoteRevisionSummary]] = [:]
    public private(set) var revisionErrors: [String: String] = [:]

    /// How long typing has to stop before a save goes out. The web uses the same figure; a note
    /// is small enough that a shorter one costs nothing but round trips, and a longer one is
    /// long enough for an app switch to lose the edit.
    public static let autosaveDelay: Duration = .milliseconds(800)

    let api: NotesApiClient
    var saveTasks: [String: Task<Void, Never>] = [:]

    /// The `PATCH` in flight for a note, distinct from `saveTasks`, which holds only its debounce
    /// timer.
    ///
    /// 🚨 A note is saved by one request at a time, and this is what enforces it. Every save reads
    /// its `expectedHash` from `details[id]` before it starts, and only moves that on the way back
    /// — so a second save started meanwhile carries a hash the first is about to invalidate, and
    /// the server answers it with a conflict describing the client's own earlier write. With
    /// typing continuing in the gap, that reads as two genuinely different bodies and raises the
    /// banner, against a note nobody else has touched. Cancelling the debounce timer does not
    /// prevent it: by then the request has left.
    var inFlightSaves: [String: Task<Void, Never>] = [:]

    // MARK: Offline

    /// What the network path monitor last said; `nil` until it has said anything. `false` is the
    /// one state in which no request is even attempted.
    var pathSatisfied: Bool?
    /// A request failed in transport since the last one that succeeded.
    var transportDown = false
    /// Whether the notes are being shown from this phone's copy because the server cannot be
    /// reached. Drives the offline banner and the online-only guards.
    public var isOffline: Bool { pathSatisfied == false || transportDown }

    /// When the index was last fetched in this run; `nil` until then, whatever the cache holds.
    public internal(set) var indexFetchedAt: Date?
    public internal(set) var lastSyncReport: NoteSyncReport?
    /// Renames and favourites made offline, by note id.
    public internal(set) var pendingFieldPatches: [String: NotePendingFieldPatch] = [:]
    /// Notes whose unsaved edit could not reach the server. Their next save sends
    /// `source: offline`, and a conflict it meets is settled by keeping this edit, which the
    /// server's version history makes safe — see ``resumeSync()``.
    public internal(set) var awaitingSync: Set<String> = []
    /// Edits restored at launch that were typed while the server was reachable and never failed
    /// to reach it (the app was killed first). They are sent as ordinary saves on the next sync,
    /// so a conflict they meet raises the banner rather than being settled by the offline policy.
    public internal(set) var unsentAtLaunch: Set<String> = []
    /// Edits the server refused, by note id, with what it said: the note was deleted elsewhere,
    /// or the request itself was rejected. Never sent again by themselves; the reader keeps or
    /// discards the text (``keptTexts``).
    public internal(set) var editRefusals: [String: String] = [:]
    /// Outbox files this build could not read, moved aside at launch.
    public internal(set) var quarantined: [NoteQuarantinedEdit] = []
    /// Notes opened without a connection and without a copy on this phone.
    public internal(set) var unavailableOffline: Set<String> = []
    public internal(set) var cacheBudgetBytes = NotesCacheBudget.defaultBytes
    /// How long reading the cached index took at launch, for the debug bridge.
    public internal(set) var indexLoadMs: Double = 0

    /// Called with what a sync settled, for the app to show. Installed by the app; nothing in
    /// the store waits on it.
    @ObservationIgnored public var onSyncNotice: ((NoteSyncNotice) -> Void)?

    @ObservationIgnored let cache: NotesCacheStorage
    @ObservationIgnored let outbox: NoteOutboxStorage
    /// Every write of a pending edit goes through this, so a keystroke's deferred write can never
    /// land after the synchronous one a request or a settled save makes.
    @ObservationIgnored let outboxWriter: NoteOutboxWriter
    /// Waiting edits parked only by a server error while the network was up.
    @ObservationIgnored var waitedForServer: Set<String> = []
    /// Of this sync pass's plain replays, the ones that had waited for the server.
    @ObservationIgnored var serverWaitReplays = 0
    @ObservationIgnored let now: @Sendable () -> Date
    /// The index rows exactly as the server last sent them, which a local rename is laid over.
    @ObservationIgnored var serverRows: [String: NoteSummary] = [:]
    /// When each unsaved edit was last typed, for the pending record.
    @ObservationIgnored var editedAtMs: [String: Int] = [:]
    /// Conflicts an offline edit met on its way to the server, by note id.
    @ObservationIgnored var syncAttempts: [String: Int] = [:]
    /// Cached bodies' `updatedAtMs`, by note id; filled once per run from disk, then kept here.
    @ObservationIgnored var bodyStamps: [String: Int]?
    @ObservationIgnored var attachmentManifest: [String: CachedAttachment] = [:]
    /// Attachment inventories fetched in this run, by container: the only ones trusted to say
    /// whether a file on disk is still the server's.
    @ObservationIgnored var freshInventories: [String: [NoteAttachmentRecord]] = [:]
    @ObservationIgnored var syncTask: Task<Void, Never>?
    @ObservationIgnored var syncCounters = NoteSyncReport()
    @ObservationIgnored var bodyMaintenance: Task<Void, Never>?
    @ObservationIgnored var parkedRetry: Task<Void, Never>?
    /// The latest attachment-manifest write; each one waits for the one before it.
    @ObservationIgnored var manifestWrite: Task<[String], Never>?
    @ObservationIgnored var parkedRetryAttempt = 0
    @ObservationIgnored let parkedRetryBaseDelay: Duration

    /// How long typing has to pause before the draft is written to the note outbox. Short against
    /// the autosave delay, so a kill between the two still finds the draft on disk.
    public static let outboxWriteDelay: Duration = .milliseconds(250)

    /// Loads the cached index and every pending edit from disk before returning, so the list and
    /// any unsaved edit are on screen in the first frame. Nothing here touches the network.
    public init(
        api: NotesApiClient,
        cache: NotesCacheStorage = InMemoryNotesCacheStorage(),
        outbox: NoteOutboxStorage = InMemoryNoteOutboxStorage(),
        now: @escaping @Sendable () -> Date = { Date() },
        parkedRetryBaseDelay: Duration = .seconds(10),
        outboxWriteDelay: Duration = NotesStore.outboxWriteDelay
    ) {
        self.api = api
        self.cache = cache
        self.outbox = outbox
        self.outboxWriter = NoteOutboxWriter(storage: outbox, delay: outboxWriteDelay)
        self.now = now
        self.parkedRetryBaseDelay = parkedRetryBaseDelay
        restoreFromDisk()
    }

    // MARK: Reading

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        // Concurrent with the index fetch, and deliberately silent on failure (`try?`) — a
        // stale or unreachable config must never surface as an error banner over the note list;
        // it just leaves `undoWindowNanos` on its short, safe fallback.
        async let configFetch = try? api.getNotesConfig()
        do {
            let fetched = try await api.getNotes(containerId: nil, favourite: nil, limit: 500, offset: 0)
            let wasOffline = transportDown
            requestSucceeded()
            adoptIndex(fetched)
            loadError = nil
            await persistIndex(fetched)
            startBodyMaintenance(index: fetched)
            // The first answer after an outage is the moment to send what waited for it. Not
            // awaited: a sync ends with a refresh of its own.
            if wasOffline, hasPendingWork { Task { [weak self] in await self?.resumeSync() } }
        } catch let error where NoteSyncFailure.isCancellation(error) {
            // Abandoned by whoever asked; the next refresh answers.
        } catch {
            // The list keeps what it holds (the cached index, at worst); the error is shown only
            // over an empty one.
            if NoteSyncFailure.isTransport(error) { markTransportDown() }
            loadError = (error as? PaiError)?.userMessage ?? "Could not load notes"
        }
        if let config = await configFetch {
            undoWindowNanos = UInt64(max(0, config.undoWindowSeconds)) * 1_000_000_000
        }
    }

    public func refreshContainers() async {
        do {
            containers = try await api.getNoteContainers()
            requestSucceeded()
        } catch {
            loadError = failureMessage(error, needing: .containers, otherwise: "Could not load note containers")
        }
    }

    // MARK: Creating, renaming, deleting

    /// Creates a note and inserts it at the front of the index — Obsidian's own convention: a
    /// brand new note is a real file the moment it is created, not a draft that only becomes one
    /// on first keystroke.
    ///
    /// The name is sent as given: when it is already taken, the server numbers it (`Name 2`) and
    /// the returned note carries the name it actually used, so the index and the caller read that
    /// one rather than what was typed. Only the server knows the collision domain — a create with
    /// no container lands in its default container, which this index cannot tell apart from a
    /// container-less note.
    public func createNote(name: String, containerId: String? = nil) async -> NoteSummary? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let created = try await api.createNote(
                name: trimmed.isEmpty ? NoteNaming.untitled : trimmed, summary: nil, body: nil,
                containerId: containerId)
            requestSucceeded()
            setDetail(created, for: created.id)
            notes.insert(created.summaryRow, at: 0)
            loadError = nil
            return created.summaryRow
        } catch {
            loadError = failureMessage(error, needing: .createNote, otherwise: "Could not create the note")
            return nil
        }
    }

    /// Without a connection the new name is kept on this phone and shown at once, and sent when
    /// the network is back (``resumeSync()``); a name the server then refuses is reported and
    /// reverted there. "Without a connection" is ``isOffline``, the same answer the screen shows.
    ///
    /// The answer is adopted through ``adoptFieldResult(_:id:)``: over an unsaved edit it moves
    /// the name and never the body or hash the edit is conditional on.
    @discardableResult
    public func rename(id: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if isOffline {
            queueFieldPatch(id: id, name: trimmed, favourite: nil)
            return true
        }
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: trimmed, summary: nil, favourite: nil,
                containerId: nil, expectedHash: nil, source: nil)
            requestSucceeded()
            guard case .saved(let detail) = result else { return false }
            adoptFieldResult(detail, id: id)
            if let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = detail.summaryRow }
            return true
        } catch {
            if NoteSyncFailure.isTransport(error) {
                markTransportDown()
                queueFieldPatch(id: id, name: trimmed, favourite: nil)
                return true
            }
            loadError = (error as? PaiError)?.userMessage ?? "Could not rename the note"
            return false
        }
    }

    /// Starts the confirm-then-undo window — the row, its embedding and its file are all
    /// untouched on the server until the finalizer fires (some seconds after the caller's own
    /// undo window closes; see ``undelete(id:)``). Marks the row `pendingDelete` locally rather
    /// than removing it, matching what the server itself did: the list still holds the row ("you get a moment to
    /// undo it").
    @discardableResult
    public func requestDelete(id: String) async -> Bool {
        do {
            _ = try await api.deleteNote(id: id)
            requestSucceeded()
            if let index = notes.firstIndex(where: { $0.id == id }) {
                let n = notes[index]
                notes[index] = NoteSummary(
                    id: n.id, name: n.name, summary: n.summary, containerId: n.containerId,
                    favourite: n.favourite, tags: n.tags, updatedAtMs: n.updatedAtMs, pendingDelete: true,
                    shared: n.shared)
            }
            return true
        } catch {
            loadError = failureMessage(error, needing: .deleteNote, otherwise: "Could not delete the note")
            return false
        }
    }

    /// Sets the share mark on a note's list row and on its loaded detail once a link is created or
    /// deleted, so the list shows it before the next index fetch confirms it. A no-op for a note
    /// this store has not loaded. Written through ``setDetail(_:for:)`` like any other change to a
    /// detail, so this phone's copy carries the mark too.
    public func markShared(id: String, shared: Bool) {
        if let index = notes.firstIndex(where: { $0.id == id }), notes[index].shared != shared {
            notes[index] = notes[index].withShared(shared)
        }
        if let held = details[id], held.shared != shared {
            setDetail(held.withShared(shared), for: id)
        }
    }

    @discardableResult
    public func undelete(id: String) async -> Bool {
        do {
            let restored = try await api.undeleteNote(id: id)
            requestSucceeded()
            setDetail(restored, for: id)
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = restored.summaryRow
            } else {
                notes.insert(restored.summaryRow, at: 0)
            }
            return true
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not undo the delete"
            return false
        }
    }

    // MARK: Containers

    @discardableResult
    public func createContainer(path: String, name: String) async -> NoteContainer? {
        do {
            let created = try await api.createNoteContainer(path: path, name: name, agentSlug: nil, isDefault: false)
            requestSucceeded()
            containers.append(created)
            return created
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not create the container"
            return nil
        }
    }

    public func validateContainerPath(_ path: String) async throws -> NoteContainerPathCheck {
        try await api.validateNoteContainerPath(path: path, agentSlug: nil)
    }

    @discardableResult
    public func setContainerEnabled(_ id: String, enabled: Bool) async -> Bool {
        await patchContainer(id) {
            try await self.api.patchNoteContainer(id: id, name: nil, enabled: enabled, isDefault: nil)
        }
    }

    @discardableResult
    public func resumeContainer(_ id: String, action: NoteContainerResumeAction) async -> Bool {
        await patchContainer(id) { try await self.api.resumeNoteContainer(id: id, action: action) }
    }

    @discardableResult
    public func deleteContainer(_ id: String) async -> Bool {
        do {
            let deleted = try await api.deleteNoteContainer(id: id)
            requestSucceeded()
            if deleted { containers.removeAll { $0.id == id } }
            return deleted
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not remove the container"
            return false
        }
    }

    private func patchContainer(_ id: String, _ request: @escaping () async throws -> NoteContainer) async -> Bool {
        do {
            let updated = try await request()
            requestSucceeded()
            if let index = containers.firstIndex(where: { $0.id == id }) { containers[index] = updated }
            return true
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not update the container"
            return false
        }
    }

    // MARK: The link index

    /// Fetches a note's outgoing links and backlinks — a snapshot, not something kept live; see
    /// this store's own doc comment on ``linkGraphs``.
    public func loadLinkGraph(id: String) async {
        do {
            linkGraphs[id] = try await api.getNoteLinks(id: id)
            requestSucceeded()
            linkGraphErrors[id] = nil
        } catch {
            linkGraphErrors[id] = failureMessage(error, needing: .links, otherwise: "Could not load links")
        }
    }

    // MARK: Revision history

    public func loadRevisions(id: String) async {
        do {
            revisions[id] = try await api.listNoteRevisions(id: id)
            requestSucceeded()
            revisionErrors[id] = nil
        } catch {
            revisionErrors[id] = failureMessage(
                error, needing: .history, otherwise: "Could not load previous versions")
        }
    }

    public func getRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail {
        try await api.getNoteRevision(noteId: noteId, revisionId: revisionId)
    }

    /// Writes the old content back as a NEW version rather than rewinding, so restoring is
    /// itself undoable. Refreshes this note's own cached detail and link graph, since both are
    /// now stale.
    @discardableResult
    public func restoreRevision(noteId: String, revisionId: String) async -> Bool {
        do {
            let restored = try await api.restoreNoteRevision(noteId: noteId, revisionId: revisionId)
            requestSucceeded()
            setDetail(restored, for: noteId)
            // The restored text is the whole point of the action, so it replaces whatever is on
            // screen — the one place a draft is deliberately dropped without asking, because
            // asking was the button that got us here.
            drafts[noteId] = nil
            bumpExternalRevision(noteId)
            saveStates[noteId] = .clean
            syncOutbox(id: noteId)
            if let index = notes.firstIndex(where: { $0.id == noteId }) { notes[index] = restored.summaryRow }
            await loadLinkGraph(id: noteId)
            await loadRevisions(id: noteId)
            return true
        } catch {
            loadError = failureMessage(error, needing: .history, otherwise: "Could not restore this version")
            return false
        }
    }

    // MARK: Full-text search

    /// A passthrough rather than stored state — the caller (the note list, debouncing its own
    /// query text) owns the results, loading state and generation guard, the same way the web's
    /// component-local `useState` does.
    public func searchNotes(q: String, window: TimeBounds?) async throws -> NoteSearchPage {
        try await api.searchNotes(q: q, containerId: nil, limit: nil, window: window)
    }

    // MARK: Attachments

    /// The container's inventory. Kept in memory and on disk on every answer, and served from
    /// there when the request cannot reach the server, so wikilinks to files still resolve
    /// offline.
    public func listAttachments(containerId: String) async throws -> [NoteAttachmentRecord] {
        do {
            let records = try await api.listNoteAttachments(containerId: containerId)
            requestSucceeded()
            freshInventories[containerId] = records
            let cache = self.cache
            await Task.detached { cache.saveInventory(records, containerId: containerId) }.value
            return records
        } catch {
            guard NoteSyncFailure.isTransport(error) else { throw error }
            markTransportDown()
            if let known = freshInventories[containerId] { return known }
            let cache = self.cache
            if let stored = await Task.detached(operation: { cache.loadInventory(containerId: containerId) }).value {
                return stored
            }
            throw error
        }
    }

    public func uploadAttachment(
        containerId: String, filename: String, mimeType: String, data: Data
    ) async throws -> NoteAttachmentUploaded {
        let uploaded = try await api.uploadNoteAttachment(
            containerId: containerId, filename: filename, mimeType: mimeType, data: data)
        requestSucceeded()
        attachmentCache.remove(containerId: containerId, path: uploaded.relPath)
        await dropCachedAttachment(containerId: containerId, path: uploaded.relPath)
        return uploaded
    }

    public func renameAttachment(
        containerId: String, fromPath: String, toPath: String
    ) async throws -> NoteAttachmentRecord {
        let renamed = try await api.renameNoteAttachment(containerId: containerId, fromPath: fromPath, toPath: toPath)
        requestSucceeded()
        attachmentCache.remove(containerId: containerId, path: fromPath)
        attachmentCache.remove(containerId: containerId, path: toPath)
        await dropCachedAttachment(containerId: containerId, path: fromPath)
        await dropCachedAttachment(containerId: containerId, path: toPath)
        return renamed
    }

    public func deleteAttachment(containerId: String, path: String) async throws -> Bool {
        let deleted = try await api.deleteNoteAttachment(containerId: containerId, path: path)
        requestSucceeded()
        attachmentCache.remove(containerId: containerId, path: path)
        await dropCachedAttachment(containerId: containerId, path: path)
        return deleted
    }

    /// Files already fetched this run. Not observed: a view reads it during its own body to draw a
    /// returning image in its first frame, and the fetch that fills it has its own state to drive
    /// the redraw.
    @ObservationIgnored var attachmentCache = NoteAttachmentCache()

    /// A file ``fetchAttachment(containerId:path:)`` already brought in, or `nil`.
    public func cachedAttachment(containerId: String, path: String) -> Data? {
        attachmentCache.data(containerId: containerId, path: path)
    }

    /// Memory first, then this phone's disk, then the server. A file on disk is served without a
    /// request unless an inventory fetched in this run says the server's copy changed; without a
    /// connection it is served regardless. A file that is not on the server is never cached, so a
    /// later sync that brings it in is picked up.
    public func fetchAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult {
        let key = CachedAttachmentKey.of(containerId: containerId, path: path)
        if let data = attachmentCache.data(containerId: containerId, path: path) {
            // A file read from memory is still a file in use: eviction goes by this.
            attachmentManifest[key]?.lastUsedMs = nowMs
            return .ok(data)
        }
        let stored = attachmentManifest[key]
        if let stored {
            let record = freshInventories[containerId]?.first { $0.relPath == path }
            let current = record.map(stored.matches) ?? true
            if current || pathSatisfied == false, let data = await readCachedAttachment(stored) {
                attachmentCache.insert(data, containerId: containerId, path: path)
                return .ok(data)
            }
        }
        let result: NoteAttachmentResult
        do {
            result = try await api.getNoteAttachment(containerId: containerId, path: path)
            requestSucceeded()
        } catch {
            guard NoteSyncFailure.isTransport(error) else { throw error }
            markTransportDown()
            // An older copy beats none when the server cannot be asked.
            if let stored, let data = await readCachedAttachment(stored) { return .ok(data) }
            throw error
        }
        switch result {
        case .ok(let data):
            attachmentCache.insert(data, containerId: containerId, path: path)
            await storeAttachment(data, containerId: containerId, path: path)
        case .notFound:
            await dropCachedAttachment(containerId: containerId, path: path)
        }
        return result
    }

    public func loadLinkHealth(containerId: String) async throws -> NoteLinkHealth {
        try await api.getNoteLinkHealth(containerId: containerId)
    }

    /// Fetch one note's content. Safe to call again for a note already open — it refreshes the
    /// baseline a save is conditional against, and never discards local typing to adopt a
    /// background fetch, which is the one thing an editor must never do on its own.
    ///
    /// A note with a copy on this phone is on screen before the request goes out; the answer then
    /// replaces it. Without a connection, that copy is all there is, and a note with none is
    /// marked ``unavailableOffline``.
    ///
    /// A note with an edit waiting to sync (``isWaitingToSend(_:)``) is not refreshed at all: its
    /// baseline is the version the edit was typed over, and moving it would let the edit overwrite
    /// whatever arrived in between. The load sends the edit instead.
    ///
    /// A load abandoned by its caller (the reader left before the answer) changes nothing: it
    /// says nothing about the network.
    ///
    /// Over an unsaved edit, the fetched body is classified the way a save's conflict is
    /// (``NoteBodyDivergence``): unchanged under the edit, it is adopted as the new baseline;
    /// already what the edit says, the edit is done; genuinely different, the conflict banner is
    /// raised and the baseline stays where the edit started, so neither version is lost.
    ///
    /// Called both on screen appear and every time the tools panel opens or refreshes, so this
    /// routinely runs alongside an autosave. Guarded against landing during or after one: this
    /// GET's answer can describe the note from before a concurrent save applied, and applying it
    /// regardless would roll ``details`` back to a hash the next autosave then sends as a stale
    /// precondition — the client conflicting with its own successful save a moment earlier.
    public func loadNote(id: String) async {
        hydrateFromCache(id: id)
        if isWaitingToSend(id) {
            if pathSatisfied != false { await replayPending(id: id) }
            return
        }
        if pathSatisfied == false {
            if details[id] == nil { unavailableOffline.insert(id) }
            return
        }
        let versionAtStart = detailVersion[id] ?? 0
        do {
            let detail = try await api.getNote(id: id)
            requestSucceeded()
            unavailableOffline.remove(id)
            guard detailVersion[id] ?? 0 == versionAtStart, inFlightSaves[id] == nil else {
                #if DEBUG
                    DebugLogBuffer.shared.append(
                        .warning, "notes-store",
                        "loadNote(\(id)) discarded: a save (or another load) wrote details[\(id)] while this "
                            + "GET was in flight — version \(versionAtStart) at the start, "
                            + "\(detailVersion[id] ?? 0) now")
                #endif
                return
            }
            if let draft = drafts[id], let base = details[id] {
                switch NoteBodyDivergence.of(server: detail.body, base: base.body, local: draft) {
                case .none:
                    break
                case .alreadyOurs:
                    saveTasks[id]?.cancel()
                    saveTasks[id] = nil
                    drafts[id] = nil
                    saveStates[id] = .clean
                    syncOutbox(id: id)
                case .real:
                    #if DEBUG
                        DebugLogBuffer.shared.append(
                            .warning, "notes-store",
                            "loadNote(\(id)) found the body moved under an unsaved edit: baseline "
                                + "\(base.contentHash.prefix(8)), server \(detail.contentHash.prefix(8))")
                    #endif
                    saveTasks[id]?.cancel()
                    saveTasks[id] = nil
                    saveStates[id] = .conflict(
                        NoteConflict(
                            currentHash: detail.contentHash, updatedAtMs: detail.updatedAtMs,
                            frontmatter: detail.frontmatter, body: detail.body))
                    syncOutbox(id: id)
                    return
                }
            }
            setDetail(detail, for: id)
            bumpExternalRevision(id)
            if drafts[id] == nil {
                saveStates[id] = .clean
            } else {
                syncOutbox(id: id)
            }
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = detail.summaryRow
            }
        } catch {
            switch NoteSyncFailure.classify(error) {
            case .cancelled:
                return
            case .transport:
                markTransportDown()
                if details[id] == nil { unavailableOffline.insert(id) }
            default:
                saveStates[id] = .failed((error as? PaiError)?.userMessage ?? "Could not open note")
            }
        }
    }

    /// The one place ``details`` is written, so a version bump can never be forgotten on one path
    /// and leave another (``loadNote``'s guard above) unable to trust it. Every version the
    /// server hands back is also this phone's copy of the note.
    func setDetail(_ detail: NoteDetail, for id: String) {
        details[id] = detail
        detailVersion[id, default: 0] += 1
        cacheBody(detail)
    }

    /// What the editor should show: the local edit if there is one, otherwise what was fetched.
    public func body(for id: String) -> String? {
        drafts[id] ?? details[id]?.body
    }

    public func externalRevision(for id: String) -> Int { externalBodyRevision[id] ?? 0 }

    func bumpExternalRevision(_ id: String) {
        externalBodyRevision[id] = externalRevision(for: id) + 1
    }

    public func detail(for id: String) -> NoteDetail? { details[id] }

    public func saveState(for id: String) -> NoteSaveState { saveStates[id] ?? .clean }

    public func summary(for id: String) -> NoteSummary? { notes.first { $0.id == id } }

    /// The note's name as it should read on screen: a rename still waiting to sync wins over
    /// what the server last said.
    public func name(for id: String) -> String? {
        pendingFieldPatches[id]?.name ?? details[id]?.name ?? summary(for: id)?.name
    }

    // MARK: Writing

    /// Record what the editor now holds and schedule a save.
    ///
    /// Cheap to call on every keystroke: an unchanged body is dropped here rather than restarting
    /// the debounce, which matters because a caret move that reports the same text would
    /// otherwise keep pushing the save out indefinitely.
    public func edit(id: String, body: String) {
        guard drafts[id] != body else { return }
        guard details[id]?.body != body || drafts[id] != nil else { return }
        drafts[id] = body
        editedAtMs[id] = Int(now().timeIntervalSince1970 * 1000)
        // Typed with no network at all: an offline edit from the first keystroke, so a kill
        // before the debounce still restores it as one.
        if pathSatisfied == false { awaitingSync.insert(id) }
        // More typing is a new attempt; a refusal of the text before it no longer describes it.
        editRefusals[id] = nil
        // On disk within ``outboxWriteDelay``, well inside the debounce; ``performSave`` writes
        // synchronously before the request leaves.
        persistDraftSoon(id: id)
        if case .conflict = saveState(for: id) {
            // A conflict is a question the reader has to answer. Typing over it does not answer
            // it, and quietly returning to `.dirty` would let the next save overwrite the vault
            // with the very thing the conflict was raised about.
            return
        }
        saveStates[id] = .dirty
        scheduleSave(id: id)
    }

    /// A task box ticked in the rendered note: an ordinary edit of the body, saved like typing
    /// (so a conflict surfaces through the same banner). `renderedBody` is the text the page was
    /// drawn from; a body that has moved since drops the tap rather than ticking whatever
    /// shifted under it. Returns whether an edit was made.
    @discardableResult
    public func toggleTask(id: String, renderedBody: String, mark: NoteTaskMark) -> Bool {
        guard body(for: id) == renderedBody, let next = NoteTasks.toggled(renderedBody, mark: mark) else {
            return false
        }
        edit(id: id, body: next)
        return true
    }

    func scheduleSave(id: String) {
        saveTasks[id]?.cancel()
        saveTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: NotesStore.autosaveDelay)
            guard !Task.isCancelled else { return }
            await self?.saveNow(id: id)
        }
    }

    /// Push the pending edit immediately, if there is one. Called when the editor is leaving the
    /// screen or the app is going to the background — the debounce is a courtesy to the network,
    /// not a reason to lose an edit.
    public func flush(id: String) async {
        guard drafts[id] != nil else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        // Awaited rather than raced: this is the path that must not lose the last stretch of
        // typing, and the cost is the one round trip already in progress.
        if let running = inFlightSaves[id] { await running.value }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        guard drafts[id] != nil else { return }
        await saveNow(id: id)
    }

    /// `adoptedHashRetries` bounds the one retry that follows adopting a hash whose divergence
    /// was outside the body. Something rewriting this note's frontmatter on every sweep would
    /// otherwise spin here forever — a real fault in its own right, and not one worth turning
    /// into an unbounded loop that never reaches the reader.
    func saveNow(id: String, adoptedHashRetries: Int = 1) async {
        if let running = inFlightSaves[id] {
            // That save reads the draft again when it returns and reschedules if anything was
            // typed meanwhile, so it already covers whatever prompted this call.
            await running.value
            return
        }
        // The slot is cleared by the task itself, as its last act, so that everyone awaiting it
        // resumes to a note with no save in flight. Clearing it here instead is a race the waiter
        // loses: it resumes first, finds the finished task still parked in the slot, waits on it
        // again and returns having saved nothing — which drops whatever was typed last.
        let task = Task { [weak self] () -> Void in
            await self?.performSave(id: id, adoptedHashRetries: adoptedHashRetries)
            self?.inFlightSaves[id] = nil
        }
        inFlightSaves[id] = task
        await task.value
    }

    /// The request itself. 🚨 Reached only through `saveNow`, which is what keeps it single-flight
    /// — the adopt-and-retry below calls it directly rather than re-entering that gate, which
    /// would wait on the task it is already running inside.
    private func performSave(id: String, adoptedHashRetries: Int) async {
        guard let pending = drafts[id], let baseline = details[id] else { return }
        if case .conflict = saveState(for: id) { return }
        // Sent now, as whatever kind of save it is below; neither a restored edit's first send
        // nor an earlier refusal describes it any more.
        unsentAtLaunch.remove(id)
        editRefusals[id] = nil
        // The edit is on disk before the request leaves; with no network it goes no further.
        // A save is never held back by ``transportDown`` alone: the request is how the store
        // learns the connection is back.
        syncOutbox(id: id)
        if pathSatisfied == false {
            park(id: id, forServer: false)
            return
        }
        // Captured before the request: whether this save is an offline edit catching up decides
        // what a conflict means below, and nothing during the request may change that answer.
        let catchingUp = awaitingSync.contains(id)
        saveStates[id] = .saving
        do {
            let result = try await api.patchNote(
                id: id, body: pending, frontmatter: baseline.frontmatter, name: nil, summary: nil,
                favourite: nil, containerId: nil, expectedHash: baseline.contentHash,
                source: catchingUp ? NoteWriteSource.offline : NoteWriteSource.phone)
            requestSucceeded()
            switch result {
            case .saved(let detail):
                setDetail(detail, for: id)
                finishWrite(id: id, sent: pending, row: detail.summaryRow, insertingRow: true)
                settleSave(id: id, caughtUp: catchingUp, overwrote: false)
            case .conflict(let conflict):
                #if DEBUG
                    DebugLogBuffer.shared.append(
                        .warning, "notes-store",
                        "saveNow(\(id)) conflict: sent expectedHash=\(baseline.contentHash.prefix(8)), "
                            + "server holds \(conflict.currentHash.prefix(8))")
                #endif
                // A hash that moved for a reason the body cannot see is not a conflict worth
                // putting in front of anyone — see ``NoteBodyDivergence``. Adopt the server's
                // hash and write again; the frontmatter that moved is the server's own, and the
                // route merges its stored copy whatever a client sends.
                switch NoteBodyDivergence.of(server: conflict.body, base: baseline.body, local: pending) {
                case .none where adoptedHashRetries > 0:
                    setDetail(baseline.adoptingHash(conflict), for: id)
                    await performSave(id: id, adoptedHashRetries: adoptedHashRetries - 1)
                case .alreadyOurs:
                    setDetail(baseline.adoptingHash(conflict), for: id)
                    finishWrite(id: id, sent: pending, row: nil)
                    settleSave(id: id, caughtUp: catchingUp, overwrote: false)
                case .none, .real:
                    if catchingUp {
                        await keepOfflineEdit(id: id, body: pending, baseline: baseline, over: conflict)
                    } else {
                        saveStates[id] = .conflict(conflict)
                        syncOutbox(id: id)
                    }
                }
            }
        } catch {
            handleSaveFailure(id: id, error: error)
        }
    }

    /// Answer a conflict.
    ///
    /// Keeping `mine` writes conditionally on the hash the conflict reported — the version the
    /// reader was shown — so a third version arriving meanwhile is another conflict rather than
    /// something overwritten unseen. It is a save of this phone's (`source: phone`), so the
    /// version it replaces stays in the history even when the web wrote it moments ago. Keeping
    /// `theirs` adopts the server's body, which is the one path here that discards typing, and so
    /// is only ever reached from an explicit choice.
    public func resolveConflict(id: String, keeping side: NoteConflictResolution) async {
        guard case .conflict(let conflict) = saveState(for: id) else { return }
        switch side {
        case .theirs:
            drafts[id] = nil
            saveStates[id] = .clean
            syncOutbox(id: id)
            await loadNote(id: id)
        case .mine:
            guard let pending = drafts[id], let baseline = details[id] else { return }
            saveStates[id] = .saving
            do {
                let result = try await api.patchNote(
                    id: id, body: pending, frontmatter: baseline.frontmatter, name: nil,
                    summary: nil, favourite: nil, containerId: nil, expectedHash: conflict.currentHash,
                    source: NoteWriteSource.phone)
                requestSucceeded()
                switch result {
                case .saved(let detail):
                    setDetail(detail, for: id)
                    finishWrite(id: id, sent: pending, row: nil)
                    syncOutbox(id: id)
                case .conflict(let again):
                    #if DEBUG
                        DebugLogBuffer.shared.append(
                            .warning, "notes-store",
                            "resolveConflict(\(id), keeping: .mine) conflicted again against "
                                + "\(again.currentHash.prefix(8)) — the vault moved on a second time")
                    #endif
                    saveStates[id] = .conflict(again)
                    syncOutbox(id: id)
                }
            } catch {
                saveStates[id] = .failed((error as? PaiError)?.userMessage ?? "Could not save")
                syncOutbox(id: id)
            }
        }
    }

    /// Retry after a `.failed` save.
    public func retrySave(id: String) async {
        guard case .failed = saveState(for: id) else { return }
        await saveNow(id: id)
    }

    /// Like ``rename(id:name:)``: kept on this phone and sent later when there is no connection,
    /// and its answer adopted without moving an unsaved edit's baseline.
    public func setFavourite(id: String, favourite: Bool) async {
        if isOffline {
            queueFieldPatch(id: id, name: nil, favourite: favourite)
            return
        }
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: nil, summary: nil, favourite: favourite,
                containerId: nil, expectedHash: nil, source: nil)
            requestSucceeded()
            guard case .saved(let detail) = result else { return }
            adoptFieldResult(detail, id: id)
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = detail.summaryRow
            }
        } catch {
            if NoteSyncFailure.isTransport(error) {
                markTransportDown()
                queueFieldPatch(id: id, name: nil, favourite: favourite)
                return
            }
            loadError = (error as? PaiError)?.userMessage ?? "Could not update favourite"
        }
    }

    /// Updates the summary shown under a note's name and matched by semantic search. An empty
    /// string clears it — the server itself treats a falsy summary as "clear", so this never has
    /// to send an explicit null. Its answer is adopted like a rename's.
    @discardableResult
    public func updateSummary(id: String, summary: String) async -> Bool {
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: nil, summary: summary, favourite: nil,
                containerId: nil, expectedHash: nil, source: nil)
            requestSucceeded()
            guard case .saved(let detail) = result else { return false }
            adoptFieldResult(detail, id: id)
            if let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = detail.summaryRow }
            return true
        } catch {
            loadError = failureMessage(error, needing: .summary, otherwise: "Could not save the summary")
            return false
        }
    }
}
