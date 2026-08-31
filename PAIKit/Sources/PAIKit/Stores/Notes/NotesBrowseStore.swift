import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol NotesBrowseApiClient: Sendable {
    func searchNotesSemantic(q: String, limit: Int) async throws -> [NoteSemanticHit]
}

extension PaiApiClient: NotesBrowseApiClient {}

/// List-browsing state that sits beside `NotesStore`'s index rather than inside it: the persisted
/// sort order, and the one call semantic search needs.
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
    }

    public private(set) var sortOrder: NoteSortOrder

    private let api: NotesBrowseApiClient
    private let storage: SettingsKeyValueStore

    public init(api: NotesBrowseApiClient, storage: SettingsKeyValueStore) {
        self.api = api
        self.storage = storage
        sortOrder = storage.value(forKey: Keys.sortOrder) ?? .modified
    }

    public func setSortOrder(_ order: NoteSortOrder) {
        sortOrder = order
        storage.setValue(order, forKey: Keys.sortOrder)
    }

    public func searchSemantic(q: String) async throws -> [NoteSemanticHit] {
        try await api.searchNotesSemantic(q: q, limit: 100)
    }
}
