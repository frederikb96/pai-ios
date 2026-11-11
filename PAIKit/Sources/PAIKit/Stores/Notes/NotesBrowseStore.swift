import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol NotesBrowseApiClient: Sendable {
    func searchNotesSemantic(q: String, window: TimeBounds?) async throws -> [NoteSemanticHit]
}

extension PaiApiClient: NotesBrowseApiClient {}

/// List-browsing state that sits beside `NotesStore`'s index rather than inside it: the persisted
/// sort order, whether the user was last reading rendered or as source, and the one call semantic
/// search needs.
///
/// Semantic search answers with a note id and a tier only, so, exactly as the web's own
/// `NoteList.tsx` does, this hands ids and tiers back to the caller, which resolves them against
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

    /// A tag the list is asked to narrow itself to, set by a tag tapped in a note and taken by the
    /// list when it appears. One-shot and in memory only: the list owns its own selection and a
    /// request must not outlive the tap that made it.
    public private(set) var requestedTag: String?

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

    /// Called from the editor's own toggle — the one place the user actively chooses a mode, as
    /// opposed to merely landing on one via `Route.notePreview`. See `previewMode`'s own doc
    /// comment for why only the toggle updates this.
    public func setPreviewMode(_ preview: Bool) {
        previewMode = preview
        storage.setValue(preview, forKey: Keys.previewMode)
    }

    /// Asks the list to show only the notes carrying `tag`. Folded to the key the list matches
    /// tags by (``noteHasAllTags(_:selected:)``), since a note may spell the tag differently from
    /// the notes that make up the vocabulary.
    public func requestTagFilter(_ tag: String) {
        requestedTag = tag.lowercased()
    }

    /// The requested tag key, once: the list calls this when it sees one and replaces its tag
    /// selection with it.
    public func takeRequestedTag() -> String? {
        defer { requestedTag = nil }
        return requestedTag
    }

    public func searchSemantic(q: String, window: TimeBounds?) async throws -> [NoteSemanticHit] {
        try await api.searchNotesSemantic(q: q, window: window)
    }
}
