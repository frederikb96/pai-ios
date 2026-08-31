import Foundation

/// Swift port of `pai-cloud/web/src/apps/notes/noteFilter.ts` — the client-side pass over the
/// already-loaded note index: deliberately not fuzzy, since this only has to be fast, and a
/// literal substring is what "typing a partial name" actually describes.

/// Case- and diacritic-insensitive: "muller" should find "Müller" on a phone keyboard that
/// doesn't make typing an umlaut convenient.
func normalizeForNoteSearch(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
}

public func noteMatchesQuery(name: String, summary: String?, query: String) -> Bool {
    let q = normalizeForNoteSearch(query.trimmingCharacters(in: .whitespacesAndNewlines))
    guard !q.isEmpty else { return true }
    if normalizeForNoteSearch(name).contains(q) { return true }
    guard let summary, !summary.isEmpty else { return false }
    return normalizeForNoteSearch(summary).contains(q)
}

public func noteMatchesQuery(_ note: NoteSummary, query: String) -> Bool {
    noteMatchesQuery(name: note.name, summary: note.summary, query: query)
}

/// One entry in the tag filter's vocabulary: the case-folded key it is matched by, the spelling
/// to show, and how many notes carry it.
public struct TagOption: Equatable, Sendable, Identifiable {
    public let key: String
    public let label: String
    public let count: Int
    public var id: String { key }
}

/// The distinct tags across the given notes, commonest first. Folded case-insensitively — `#SVA`
/// and `#sva` are one tag, as they are in Obsidian — keeping the first spelling seen so the list
/// reads the way Freddy writes rather than flattened to lower case.
public func collectTags(_ notes: [NoteSummary]) -> [TagOption] {
    var order: [String] = []
    var counts: [String: Int] = [:]
    var labels: [String: String] = [:]
    for note in notes {
        for raw in note.tags {
            let key = raw.lowercased()
            if counts[key] == nil {
                order.append(key)
                labels[key] = raw
            }
            counts[key, default: 0] += 1
        }
    }
    return order.map { TagOption(key: $0, label: labels[$0] ?? $0, count: counts[$0] ?? 0) }
        .sorted { a, b in
            a.count != b.count ? a.count > b.count : a.key < b.key
        }
}

/// AND across every selected tag, never OR. `selected` holds case-folded keys.
public func noteHasAllTags(_ note: NoteSummary, selected: [String]) -> Bool {
    guard !selected.isEmpty else { return true }
    let present = Set(note.tags.map { $0.lowercased() })
    return selected.allSatisfy { present.contains($0) }
}

/// How the note list orders its rows. `.modified` is the long-standing default; the other two
/// use only fields the list route already returns. There is deliberately no `.created` case: the
/// list route (`NoteSummary`) never carries a creation timestamp, only `NoteDetail` does, so
/// offering it here would need a backend field added to `GET /api/notes` first.
public enum NoteSortOrder: String, Codable, Sendable, CaseIterable, Identifiable {
    case modified, name, favouritesFirst
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .modified: return "Last modified"
        case .name: return "Name"
        case .favouritesFirst: return "Favourites first"
        }
    }
}

/// Orders an already-filtered slice of the index. Every case breaks its own ties on
/// `updatedAtMs` descending, so the list never looks unordered within a tied group. `.name`
/// folds case and diacritics the same way `noteMatchesQuery` above does, so "müller" and
/// "Müller" sit together rather than split across an upper/lower-case boundary.
public func sortNotes(_ notes: [NoteSummary], order: NoteSortOrder) -> [NoteSummary] {
    switch order {
    case .modified:
        return notes.sorted { $0.updatedAtMs > $1.updatedAtMs }
    case .name:
        return notes.sorted { a, b in
            let (na, nb) = (normalizeForNoteSearch(a.name), normalizeForNoteSearch(b.name))
            return na != nb ? na < nb : a.updatedAtMs > b.updatedAtMs
        }
    case .favouritesFirst:
        return notes.sorted { a, b in
            a.favourite != b.favourite ? a.favourite : a.updatedAtMs > b.updatedAtMs
        }
    }
}
