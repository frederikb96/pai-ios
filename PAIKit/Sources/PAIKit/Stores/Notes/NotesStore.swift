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
    func getNoteContainers() async throws -> [NoteContainer]
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
    /// The body as it currently stands on screen, for a note edited since it was loaded.
    public private(set) var drafts: [String: String] = [:]
    public private(set) var saveStates: [String: NoteSaveState] = [:]

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

    /// Fetch one note's content. Safe to call again for a note already open — it refreshes the
    /// baseline a save is conditional against, and deliberately leaves any local edit alone,
    /// since discarding typing to adopt a background fetch is the one thing an editor must never
    /// do on its own.
    public func loadNote(id: String) async {
        do {
            let detail = try await api.getNote(id: id)
            details[id] = detail
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

    /// What the editor should show: the local edit if there is one, otherwise what was fetched.
    public func body(for id: String) -> String? {
        drafts[id] ?? details[id]?.body
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
                details[id] = detail
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
                    details[id] = detail
                    if drafts[id] == pending {
                        drafts[id] = nil
                        saveStates[id] = .clean
                    } else {
                        saveStates[id] = .dirty
                        scheduleSave(id: id)
                    }
                case .conflict(let again):
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
            details[id] = detail
            if let index = notes.firstIndex(where: { $0.id == id }) {
                notes[index] = detail.summaryRow
            }
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not update favourite"
        }
    }
}
