import AppIntents
import Foundation
import PAIKit

/// A note, as the Shortcuts app sees it.
///
/// The whole point of the entity is the picker: Freddy chooses a note by name once, and iOS
/// stores its id in the shortcut. That is why the id is what travels and the name is only for
/// display — a shortcut built today has to still open the right note after the note is renamed.
struct NoteEntity: AppEntity, Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String?

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Note" }

    var displayRepresentation: DisplayRepresentation {
        if let summary, !summary.isEmpty {
            return DisplayRepresentation(title: "\(name)", subtitle: "\(summary)")
        }
        return DisplayRepresentation(title: "\(name)")
    }

    static var defaultQuery: NoteEntityQuery { NoteEntityQuery() }

    init(id: String, name: String, summary: String?) {
        self.id = id
        self.name = name
        self.summary = summary
    }

    init(_ note: NoteSummary) {
        self.init(id: note.id, name: note.name, summary: note.summary)
    }
}

/// How Shortcuts finds notes to offer.
///
/// Fetches through a client built from stored credentials rather than from the running app: this
/// is asked while the app is not running — that is the normal case, since a person configures a
/// shortcut and then never opens the app to use it.
///
/// Every failure answers with an empty list rather than throwing. A thrown error in a picker
/// reads as a broken shortcut; an empty list reads as a vault with nothing in it yet, which is
/// closer to true for the two cases that actually produce it (not signed in, backend
/// unreachable) and leaves the shortcut usable once either is fixed.
struct NoteEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [NoteEntity] {
        // Resolved from the index rather than fetched one by one: a shortcut names a single note,
        // but the list is one request where per-id lookups are one request each, and a note that
        // has since been deleted must drop out of the answer rather than fail the whole batch.
        let wanted = Set(identifiers)
        return await allNotes().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [NoteEntity] {
        let needle = string.lowercased()
        guard !needle.isEmpty else { return await allNotes() }
        return await allNotes().filter { $0.name.lowercased().contains(needle) }
    }

    /// What the picker shows before anything is typed. Favourites first, because a shortcut is
    /// something Freddy makes for a note he returns to, and that is what a favourite already is.
    func suggestedEntities() async throws -> [NoteEntity] {
        await allNotes()
    }

    private func allNotes() async -> [NoteEntity] {
        guard let client = await AppEnvironment.standaloneClient() else { return [] }
        guard let notes = try? await client.getNotes() else { return [] }
        return
            notes
            .sorted { lhs, rhs in
                if lhs.favourite != rhs.favourite { return lhs.favourite }
                return lhs.updatedAtMs > rhs.updatedAtMs
            }
            .map(NoteEntity.init)
    }
}
