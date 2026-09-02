import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol NotesApiClient: Sendable {
    func getNotes(containerId: String?, favourite: Bool?, limit: Int, offset: Int) async throws -> [NoteSummary]
    func getNote(id: String) async throws -> NoteDetail
    func patchNote(
        id: String, body: String?, frontmatter: String?, name: String?, summary: String?,
        favourite: Bool?, containerId: String?, expectedHash: String?
    ) async throws -> NoteSaveResult
    func createNote(name: String, summary: String?, body: String?, containerId: String?) async throws -> NoteDetail
    func deleteNote(id: String) async throws -> Bool
    func undeleteNote(id: String) async throws -> NoteDetail
    func getNoteLinks(id: String) async throws -> NoteLinkGraph
    func listNoteRevisions(id: String) async throws -> [NoteRevisionSummary]
    func getNoteRevision(noteId: String, revisionId: String) async throws -> NoteRevisionDetail
    func restoreNoteRevision(noteId: String, revisionId: String) async throws -> NoteDetail
    func searchNotes(q: String, containerId: String?, limit: Int?) async throws -> NoteSearchPage

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
    /// The save failed for a reason that is not a conflict. The edit is still held in memory, so
    /// the recovery is to try again rather than to retype.
    case failed(String)
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

    public private(set) var notes: [NoteSummary] = []
    public private(set) var containers: [NoteContainer] = []
    public private(set) var loadError: String?
    public private(set) var isLoading = false

    // MARK: Open notes

    /// The last content read from the server, per note id. What a save is conditional against.
    public private(set) var details: [String: NoteDetail] = [:]
    /// Bumped every time ``details`` is written for a note, by any of `loadNote`, `saveNow` or
    /// `resolveConflict`. A `loadNote` in flight captures this before its request goes out and
    /// checks it again before applying the response — if a save landed in between, the load's
    /// answer describes a note that no longer exists and is dropped rather than rolling the
    /// baseline back to a hash the next autosave would send as a now-stale precondition.
    private var detailVersion: [String: Int] = [:]
    /// The body as it currently stands on screen, for a note edited since it was loaded.
    public private(set) var drafts: [String: String] = [:]
    public private(set) var saveStates: [String: NoteSaveState] = [:]
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
    // this list while Freddy types, so it only ever refreshes on an explicit reload.

    public private(set) var linkGraphs: [String: NoteLinkGraph] = [:]
    public private(set) var linkGraphErrors: [String: String] = [:]

    // MARK: Revision history, per note

    public private(set) var revisions: [String: [NoteRevisionSummary]] = [:]
    public private(set) var revisionErrors: [String: String] = [:]

    /// How long typing has to stop before a save goes out. The web uses the same figure; a note
    /// is small enough that a shorter one costs nothing but round trips, and a longer one is
    /// long enough for an app switch to lose the edit.
    public static let autosaveDelay: Duration = .milliseconds(800)

    private let api: NotesApiClient
    private var saveTasks: [String: Task<Void, Never>] = [:]

    public init(api: NotesApiClient) {
        self.api = api
    }

    // MARK: Reading

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            notes = try await api.getNotes(containerId: nil, favourite: nil, limit: 500, offset: 0)
            loadError = nil
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load notes"
        }
    }

    public func refreshContainers() async {
        do {
            containers = try await api.getNoteContainers()
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load note containers"
        }
    }

    // MARK: Creating, renaming, deleting

    /// Creates a note and inserts it at the front of the index — Obsidian's own convention: a
    /// brand new note is a real file the moment it is created, not a draft that only becomes one
    /// on first keystroke.
    ///
    /// The name is made free before it is asked for — see ``NoteNaming/freeName(base:taken:)``.
    /// Creating a note is not the same act as naming one, and a "New note" button that fails
    /// because a note called `Untitled` already exists has no way forward at all.
    ///
    /// `taken` excludes `pendingDelete` rows — `requestDelete` marks a row rather than removing
    /// it, for the undo window, and nothing here ever prunes it back out short of a full
    /// `refresh()`. Counting it as taken anyway is what let repeated create-then-delete climb the
    /// number forever: the server had long since finished deleting the note, but this index had
    /// not caught up and had no reason to before this call ran again.
    public func createNote(name: String, containerId: String? = nil) async -> NoteSummary? {
        let free = NoteNaming.freeName(
            base: name,
            taken: notes.filter { !$0.pendingDelete && $0.containerId == containerId }
                .map(\.name))
        do {
            let created = try await api.createNote(name: free, summary: nil, body: nil, containerId: containerId)
            setDetail(created, for: created.id)
            notes.insert(created.summaryRow, at: 0)
            loadError = nil
            return created.summaryRow
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not create the note"
            return nil
        }
    }

    @discardableResult
    public func rename(id: String, name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: trimmed, summary: nil, favourite: nil,
                containerId: nil, expectedHash: nil)
            guard case .saved(let detail) = result else { return false }
            setDetail(detail, for: id)
            if let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = detail.summaryRow }
            return true
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not rename the note"
            return false
        }
    }

    /// Starts the confirm-then-undo window — the row, its embedding and its file are all
    /// untouched on the server until the finalizer fires (some seconds after the caller's own
    /// undo window closes; see ``undelete(id:)``). Marks the row `pendingDelete` locally rather
    /// than removing it, matching what the server itself did: the list still holds the row (spec
    /// row 5.4's "you get a moment to undo it").
    @discardableResult
    public func requestDelete(id: String) async -> Bool {
        do {
            _ = try await api.deleteNote(id: id)
            if let index = notes.firstIndex(where: { $0.id == id }) {
                let n = notes[index]
                notes[index] = NoteSummary(
                    id: n.id, name: n.name, summary: n.summary, containerId: n.containerId,
                    favourite: n.favourite, tags: n.tags, updatedAtMs: n.updatedAtMs, pendingDelete: true)
            }
            return true
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not delete the note"
            return false
        }
    }

    @discardableResult
    public func undelete(id: String) async -> Bool {
        do {
            let restored = try await api.undeleteNote(id: id)
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
            linkGraphErrors[id] = nil
        } catch {
            linkGraphErrors[id] = (error as? PaiError)?.userMessage ?? "Could not load links"
        }
    }

    // MARK: Revision history

    public func loadRevisions(id: String) async {
        do {
            revisions[id] = try await api.listNoteRevisions(id: id)
            revisionErrors[id] = nil
        } catch {
            revisionErrors[id] = (error as? PaiError)?.userMessage ?? "Could not load previous versions"
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
            setDetail(restored, for: noteId)
            // The restored text is the whole point of the action, so it replaces whatever is on
            // screen — the one place a draft is deliberately dropped without asking, because
            // asking was the button that got us here.
            drafts[noteId] = nil
            bumpExternalRevision(noteId)
            saveStates[noteId] = .clean
            if let index = notes.firstIndex(where: { $0.id == noteId }) { notes[index] = restored.summaryRow }
            await loadLinkGraph(id: noteId)
            await loadRevisions(id: noteId)
            return true
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not restore this version"
            return false
        }
    }

    // MARK: Full-text search

    /// A passthrough rather than stored state — the caller (the note list, debouncing its own
    /// query text) owns the results, loading state and generation guard, the same way the web's
    /// component-local `useState` does.
    public func searchNotes(q: String) async throws -> NoteSearchPage {
        try await api.searchNotes(q: q, containerId: nil, limit: nil)
    }

    // MARK: Attachments

    public func listAttachments(containerId: String) async throws -> [NoteAttachmentRecord] {
        try await api.listNoteAttachments(containerId: containerId)
    }

    public func uploadAttachment(
        containerId: String, filename: String, mimeType: String, data: Data
    ) async throws -> NoteAttachmentUploaded {
        try await api.uploadNoteAttachment(containerId: containerId, filename: filename, mimeType: mimeType, data: data)
    }

    public func renameAttachment(
        containerId: String, fromPath: String, toPath: String
    ) async throws -> NoteAttachmentRecord {
        try await api.renameNoteAttachment(containerId: containerId, fromPath: fromPath, toPath: toPath)
    }

    public func deleteAttachment(containerId: String, path: String) async throws -> Bool {
        try await api.deleteNoteAttachment(containerId: containerId, path: path)
    }

    public func fetchAttachment(containerId: String, path: String) async throws -> NoteAttachmentResult {
        try await api.getNoteAttachment(containerId: containerId, path: path)
    }

    public func loadLinkHealth(containerId: String) async throws -> NoteLinkHealth {
        try await api.getNoteLinkHealth(containerId: containerId)
    }

    /// Fetch one note's content. Safe to call again for a note already open — it refreshes the
    /// baseline a save is conditional against, and deliberately leaves any local edit alone,
    /// since discarding typing to adopt a background fetch is the one thing an editor must never
    /// do on its own.
    ///
    /// Called both on screen appear and every time the tools panel opens or refreshes, so this
    /// routinely runs alongside an autosave. Guarded against landing after one: this GET's answer
    /// can describe the note from before a concurrent save applied, and applying it regardless
    /// would roll ``details`` back to a hash the next autosave then sends as a stale precondition
    /// — the client conflicting with its own successful save a moment earlier.
    public func loadNote(id: String) async {
        let versionAtStart = detailVersion[id] ?? 0
        do {
            let detail = try await api.getNote(id: id)
            guard detailVersion[id] ?? 0 == versionAtStart else {
                #if DEBUG
                    DebugLogBuffer.shared.append(
                        .warning, "notes-store",
                        "loadNote(\(id)) discarded: a save (or another load) wrote details[\(id)] while this "
                            + "GET was in flight — version \(versionAtStart) at the start, "
                            + "\(detailVersion[id] ?? 0) now")
                #endif
                return
            }
            setDetail(detail, for: id)
            bumpExternalRevision(id)
            if drafts[id] == nil {
                saveStates[id] = .clean
            }
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = detail.summaryRow
            }
        } catch {
            saveStates[id] = .failed((error as? PaiError)?.userMessage ?? "Could not open note")
        }
    }

    /// The one place ``details`` is written, so a version bump can never be forgotten on one path
    /// and leave another (``loadNote``'s guard above) unable to trust it.
    private func setDetail(_ detail: NoteDetail, for id: String) {
        details[id] = detail
        detailVersion[id, default: 0] += 1
    }

    /// What the editor should show: the local edit if there is one, otherwise what was fetched.
    public func body(for id: String) -> String? {
        drafts[id] ?? details[id]?.body
    }

    public func externalRevision(for id: String) -> Int { externalBodyRevision[id] ?? 0 }

    private func bumpExternalRevision(_ id: String) {
        externalBodyRevision[id] = externalRevision(for: id) + 1
    }

    public func detail(for id: String) -> NoteDetail? { details[id] }

    public func saveState(for id: String) -> NoteSaveState { saveStates[id] ?? .clean }

    public func summary(for id: String) -> NoteSummary? { notes.first { $0.id == id } }

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
        if case .conflict = saveState(for: id) {
            // A conflict is a question the reader has to answer. Typing over it does not answer
            // it, and quietly returning to `.dirty` would let the next save overwrite the vault
            // with the very thing the conflict was raised about.
            return
        }
        saveStates[id] = .dirty
        scheduleSave(id: id)
    }

    private func scheduleSave(id: String) {
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
        await saveNow(id: id)
    }

    private func saveNow(id: String) async {
        guard let pending = drafts[id], let baseline = details[id] else { return }
        if case .conflict = saveState(for: id) { return }
        saveStates[id] = .saving
        do {
            let result = try await api.patchNote(
                id: id, body: pending, frontmatter: baseline.frontmatter, name: nil, summary: nil,
                favourite: nil, containerId: nil, expectedHash: baseline.contentHash)
            switch result {
            case .saved(let detail):
                setDetail(detail, for: id)
                // Only clear the draft if nothing was typed while the request was in flight —
                // otherwise the newer keystrokes would be dropped and the editor would show text
                // the server has never seen while reporting itself clean.
                if drafts[id] == pending {
                    drafts[id] = nil
                    saveStates[id] = .clean
                } else {
                    saveStates[id] = .dirty
                    scheduleSave(id: id)
                }
                if let index = notes.firstIndex(where: { $0.id == id }) {
                    notes[index] = detail.summaryRow
                } else {
                    notes.insert(detail.summaryRow, at: 0)
                }
            case .conflict(let conflict):
                #if DEBUG
                    DebugLogBuffer.shared.append(
                        .warning, "notes-store",
                        "saveNow(\(id)) conflict: sent expectedHash=\(baseline.contentHash.prefix(8)), "
                            + "server holds \(conflict.currentHash.prefix(8))")
                #endif
                saveStates[id] = .conflict(conflict)
            }
        } catch {
            saveStates[id] = .failed((error as? PaiError)?.userMessage ?? "Could not save")
        }
    }

    /// Answer a conflict.
    ///
    /// Keeping `mine` writes unconditionally — the whole point is that the hash no longer
    /// matches, so a conditional retry would conflict again forever. Keeping `theirs` adopts the
    /// server's body, which is the one path here that discards typing, and so is only ever
    /// reached from an explicit choice.
    public func resolveConflict(id: String, keeping side: NoteConflictResolution) async {
        guard case .conflict(let conflict) = saveState(for: id) else { return }
        switch side {
        case .theirs:
            drafts[id] = nil
            saveStates[id] = .clean
            await loadNote(id: id)
        case .mine:
            guard let pending = drafts[id], let baseline = details[id] else { return }
            saveStates[id] = .saving
            do {
                let result = try await api.patchNote(
                    id: id, body: pending, frontmatter: baseline.frontmatter, name: nil,
                    summary: nil, favourite: nil, containerId: nil, expectedHash: conflict.currentHash)
                switch result {
                case .saved(let detail):
                    setDetail(detail, for: id)
                    if drafts[id] == pending {
                        drafts[id] = nil
                        saveStates[id] = .clean
                    } else {
                        saveStates[id] = .dirty
                        scheduleSave(id: id)
                    }
                case .conflict(let again):
                    #if DEBUG
                        DebugLogBuffer.shared.append(
                            .warning, "notes-store",
                            "resolveConflict(\(id), keeping: .mine) conflicted again against "
                                + "\(again.currentHash.prefix(8)) — the vault moved on a second time")
                    #endif
                    saveStates[id] = .conflict(again)
                }
            } catch {
                saveStates[id] = .failed((error as? PaiError)?.userMessage ?? "Could not save")
            }
        }
    }

    /// Retry after a `.failed` save.
    public func retrySave(id: String) async {
        guard case .failed = saveState(for: id) else { return }
        await saveNow(id: id)
    }

    public func setFavourite(id: String, favourite: Bool) async {
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: nil, summary: nil, favourite: favourite,
                containerId: nil, expectedHash: nil)
            guard case .saved(let detail) = result else { return }
            setDetail(detail, for: id)
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = detail.summaryRow
            }
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not update favourite"
        }
    }

    /// Updates the summary shown under a note's name and matched by semantic search. An empty
    /// string clears it — the server itself treats a falsy summary as "clear", so this never has
    /// to send an explicit null.
    @discardableResult
    public func updateSummary(id: String, summary: String) async -> Bool {
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: nil, summary: summary, favourite: nil,
                containerId: nil, expectedHash: nil)
            guard case .saved(let detail) = result else { return false }
            setDetail(detail, for: id)
            if let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = detail.summaryRow }
            return true
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not save the summary"
            return false
        }
    }
}
