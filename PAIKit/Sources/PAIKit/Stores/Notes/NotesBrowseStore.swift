import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol NotesBrowseApiClient: Sendable {
    func searchNotesSemantic(q: String, limit: Int) async throws -> [NoteSemanticHit]
}

extension PaiApiClient: NotesBrowseApiClient {}

/// List-browsing state that sits beside `NotesStore`'s index rather than inside it: the persisted
/// sort order, whether Freddy was last reading rendered or as source, and the one call semantic
/// search needs.
///
/// Semantic search answers with a note id and a score only — `embed_note`'s job handler stores
/// `{"note_id": ...}` as a memory row's whole metadata — so, exactly as the web's own
/// `NoteList.tsx` does, this hands ids and scores back to the caller, which resolves them against
/// `NotesStore.notes` rather than trusting the search route for a name or summary that could have
/// changed since the note was last embedded.
///
/// `searchSemantic` is a passthrough rather than stored state, mirroring `NotesStore.searchNotes`'s
/// own doc comment: the caller debounces its own query text and owns the results and the loading
/// flag, and SwiftUI's `.task(id:)` already cancels the previous search when the query changes —
/// a second copy of that bookkeeping here could only drift from it.
@MainActor
@Observable
public final class NotesBrowseStore {
    private enum Keys {
        static let sortOrder = "notesSortOrder"
        static let previewMode = "notesPreviewMode"
    }

    public private(set) var sortOrder: NoteSortOrder
    /// Whether a note opened with no mode of its own — `Route.note`, reached by picking a note
    /// from the list or by anything else that does not name a mode — should start rendered. A
    /// reading preference, not account state, so it is a device default rather than something the
    /// backend carries: `Route.notePreview` (a wikilink, a shared link, the fixture workflow)
    /// still always starts rendered regardless of this, the same way the web's own address wins
    /// over its stored preference whenever the address actually names a mode.
    public private(set) var previewMode: Bool

    private let api: NotesBrowseApiClient
    private let storage: SettingsKeyValueStore

    public init(api: NotesBrowseApiClient, storage: SettingsKeyValueStore) {
        self.api = api
        self.storage = storage
        sortOrder = storage.value(forKey: Keys.sortOrder) ?? .modified
        previewMode = storage.value(forKey: Keys.previewMode) ?? false
    }

    public func setSortOrder(_ order: NoteSortOrder) {
        sortOrder = order
        storage.setValue(order, forKey: Keys.sortOrder)
    }

    /// Called from the editor's own toggle — the one place Freddy actively chooses a mode, as
    /// opposed to merely landing on one via `Route.notePreview`. See `previewMode`'s own doc
    /// comment for why only the toggle updates this.
    public func setPreviewMode(_ preview: Bool) {
        previewMode = preview
        storage.setValue(preview, forKey: Keys.previewMode)
    }

    public func searchSemantic(q: String) async throws -> [NoteSemanticHit] {
        try await api.searchNotesSemantic(q: q, limit: 100)
    }
}
