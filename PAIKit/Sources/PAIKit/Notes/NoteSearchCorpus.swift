import Foundation

/// One note, folded and tokenised ready to be scored.
public struct PreparedNote: Sendable {
    public let note: NoteSummary
    public let name: FuzzyField
    public let summary: FuzzyField?
}

/// The note index, held in the shape the filter actually reads it in.
///
/// A query changes on every keystroke; the vault does not. Folding and tokenising ~1,800 notes
/// costs roughly 35ms, which is most of the work a keystroke would otherwise do and enough to
/// be felt as lag on every single character. Doing it once and reusing it leaves the per-
/// keystroke cost as the comparisons themselves, which is what it should have been all along.
///
/// The cache is keyed by note id and validated against the text it was built from, so an edit,
/// a rename or a new note re-prepares that one note and nothing else — there is no version
/// counter to keep in step with the eight places `NotesStore` mutates its index, and therefore
/// no way for the cache to quietly serve stale text.
///
/// Held by the screen (a `@State` object), not by a store: it is a derived read model with no
/// state of its own worth persisting, and it should die with the screen that was typing into it.
@MainActor
public final class NoteSearchCorpus {
    private struct Entry {
        let name: String
        let summary: String?
        let prepared: PreparedNote
    }

    private var cache: [String: Entry] = [:]
    private var lastInput: [NoteSummary] = []
    private var lastResult: [PreparedNote] = []

    public init() {}

    public func prepared(_ notes: [NoteSummary]) -> [PreparedNote] {
        // The index does not move between keystrokes, so the common case is being handed the
        // very same array again. Array equality short-circuits on identical storage, which makes
        // this free in that case and cheap in every other — without it, a keystroke pays for a
        // dictionary lookup and an array rebuild per note for a corpus that did not change.
        if notes == lastInput { return lastResult }
        var refreshed: [String: Entry] = [:]
        refreshed.reserveCapacity(notes.count)
        var result: [PreparedNote] = []
        result.reserveCapacity(notes.count)
        for note in notes {
            if let hit = cache[note.id], hit.name == note.name, hit.summary == note.summary {
                // The stored `NoteSummary` still has to be replaced: everything else about a row
                // — favourite, tags, the modified stamp — can move without the text moving, and
                // serving the cached copy would hand the list a stale row that renders wrongly
                // while matching correctly.
                let prepared = PreparedNote(note: note, name: hit.prepared.name, summary: hit.prepared.summary)
                refreshed[note.id] = Entry(name: hit.name, summary: hit.summary, prepared: prepared)
                result.append(prepared)
                continue
            }
            let prepared = PreparedNote(
                note: note,
                name: FuzzyField(folded: normalizeForNoteSearch(note.name)),
                summary: note.summary.map { FuzzyField(folded: normalizeForNoteSearch($0)) })
            refreshed[note.id] = Entry(name: note.name, summary: note.summary, prepared: prepared)
            result.append(prepared)
        }
        // Replacing rather than merging is what bounds this: a deleted note's entry goes with
        // the pass that stopped mentioning it, so the cache can never outgrow the index.
        cache = refreshed
        lastInput = notes
        lastResult = result
        return result
    }
}
