import Foundation

/// Swift port of `pai-cloud/web/src/apps/notes/noteFilter.ts` — the client-side pass over the
/// already-loaded note index.
///
/// Scored the same way the session list is scored, through ``FuzzyTextScore``, rather than by a
/// literal substring: typing a partial name is only one of the things a person does to a filter
/// box, and the other two — the words in the wrong order, and a character dropped or swapped —
/// are what make a filter feel broken when they fail. A substring test answers "nothing matches"
/// to both, which is indistinguishable from the note not existing.
///
/// Client-side and undebounced, unlike the session list's own search: the whole note index is
/// already in memory, so there is nothing to wait for and nothing to ask.

/// Case- and diacritic-insensitive: "muller" should find "Müller" on a phone keyboard that
/// doesn't make typing an umlaut convenient.
func normalizeForNoteSearch(_ text: String) -> String {
    text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
}

/// A query prepared once for a whole pass over the index — folding it and splitting it per note
/// is pure waste when there is one query and a vault of candidates.
public struct NoteSearchQuery: Sendable {
    public let fuzzy: FuzzyQuery
    public var isEmpty: Bool { fuzzy.isEmpty }

    public init(_ raw: String) {
        fuzzy = FuzzyQuery(normalized: normalizeForNoteSearch(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
    }
}

/// How well a note answers the query. Zero is no match — the list filters on that, so "shows up"
/// and "shows up high" are one decision rather than a match test plus a separate ranking.
///
/// The name is the thing being searched for and the summary supports it, which is the same split
/// `search.py` makes between a session's title and its working directory.
public func noteMatchScore(_ prepared: PreparedNote, query: NoteSearchQuery) -> Double {
    guard !query.isEmpty else { return FuzzyTextScore.base }
    let nameScore = FuzzyTextScore.textScore(field: prepared.name, query: query.fuzzy)
    let summaryScore = FuzzyTextScore.secondaryScore(field: prepared.summary, query: query.fuzzy)
    if nameScore <= 0 && summaryScore <= 0 { return 0 }
    return FuzzyTextScore.base + nameScore + summaryScore
}

/// Scores one note with nothing cached — for a caller holding a single note rather than an index.
/// The list never uses this: preparing per note is the cost ``NoteSearchCorpus`` exists to avoid.
public func noteMatchScore(name: String, summary: String?, query: NoteSearchQuery) -> Double {
    let prepared = PreparedNote(
        note: NoteSummary(
            id: "", name: name, summary: summary, containerId: nil, favourite: false, tags: [],
            updatedAtMs: 0, pendingDelete: false),
        name: FuzzyField(folded: normalizeForNoteSearch(name)),
        summary: summary.map { FuzzyField(folded: normalizeForNoteSearch($0)) })
    return noteMatchScore(prepared, query: query)
}

public func noteMatchesQuery(name: String, summary: String?, query: String) -> Bool {
    noteMatchScore(name: name, summary: summary, query: NoteSearchQuery(query)) > 0
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

/// The note list's whole text pass: which notes the query admits, and in what order.
///
/// With a query present the order is the match score, exactly as a session search result is
/// ordered — "the closest match first" is the only order a search has, and leaving a scored
/// result in modified-date order hides the note that was typed for behind ones that merely
/// mention a word from it. Ties break on recency, so the order is total. An empty query is not
/// a search at all and keeps whichever order Freddy chose.
///
/// Takes prepared notes rather than raw ones so the folding and tokenising survive between
/// keystrokes — see ``NoteSearchCorpus``.
public func searchAndSortNotes(_ notes: [PreparedNote], query: String, order: NoteSortOrder) -> [NoteSummary] {
    let prepared = NoteSearchQuery(query)
    guard !prepared.isEmpty else { return sortNotes(notes.map(\.note), order: order) }
    // Written as statements rather than one chain on purpose: the inferred tuple element types
    // through `compactMap` → `sorted` → `map` defeat the type checker in a Release build, which
    // is the one build nothing here compiles until a macOS runner does.
    var scored: [(score: Double, note: NoteSummary)] = []
    scored.reserveCapacity(notes.count)
    for candidate in notes {
        let score = noteMatchScore(candidate, query: prepared)
        if score > 0 { scored.append((score: score, note: candidate.note)) }
    }
    scored.sort { a, b in
        a.score != b.score ? a.score > b.score : a.note.updatedAtMs > b.note.updatedAtMs
    }
    return scored.map(\.note)
}
