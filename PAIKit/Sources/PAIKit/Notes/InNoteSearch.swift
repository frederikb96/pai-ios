import Foundation

/// How much surrounding text an occurrence carries, on each side, for the "find in this note"
/// panel's context snippet.
private let noteSearchContextChars = 40

/// One occurrence of a search string within a note body — a Character offset to jump to, plus
/// enough surrounding text to preview the hit inline.
///
/// `offset` and `length` are both counted against the same `body` this occurrence was found in —
/// never against `context`, which is a snippet in its own, shorter coordinate space. A caller
/// wanting to highlight the match slices `body`, or whatever text was passed as `body`, at
/// `offset..<(offset + length)`; it must never apply these numbers to `context` or to any other
/// text than the one `findOccurrences` was called with.
public struct NoteOccurrence: Equatable, Sendable, Identifiable {
    public let offset: Int
    public let length: Int
    public let context: String
    public var id: Int { offset }
}

/// Every occurrence of `query` within `body` — a plain substring pass, matching how the whole
/// vault's full-text search already works rather than introducing a second matching rule for one
/// note. Swift port of `InNoteSearchPanel.tsx`'s `findOccurrences`.
///
/// Matches directly against `body` with `.caseInsensitive`, rather than lower-casing `body` and
/// `query` into separate Character arrays first and treating a position in one as a position in
/// the other. `String.lowercased()` is not guaranteed to preserve grapheme-cluster boundaries
/// 1:1 with the original — a case fold can occasionally reshape a cluster — and once it doesn't,
/// every match found after that point in a lower-cased haystack lands at the wrong offset in the
/// original `bodyChars`, so its `context` snippet is sliced from unrelated text nowhere near the
/// real match. Searching the original text directly makes that misalignment impossible rather
/// than merely unlikely.
public func findOccurrences(body: String, query: String) -> [NoteOccurrence] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    let bodyChars = Array(body)

    var occurrences: [NoteOccurrence] = []
    var searchStart = body.startIndex
    while searchStart < body.endIndex,
        let match = body.range(of: needle, options: .caseInsensitive, range: searchStart..<body.endIndex)
    {
        let offset = body.distance(from: body.startIndex, to: match.lowerBound)
        let length = body.distance(from: match.lowerBound, to: match.upperBound)
        let start = max(0, offset - noteSearchContextChars)
        let end = min(bodyChars.count, offset + length + noteSearchContextChars)
        occurrences.append(NoteOccurrence(offset: offset, length: length, context: String(bodyChars[start..<end])))
        searchStart = match.upperBound
    }
    return occurrences
}

/// Every occurrence of `query` in `text`, as a Character range directly usable to paint a
/// highlight in `text` itself.
///
/// This is the composition a highlighting caller actually needs — ``findOccurrences(body:query:)``
/// alone is not: its `context` snippet exists only for the results-list preview, and using
/// anything derived from it as an offset into `text` is exactly the bug this function exists to
/// make impossible at the call site, by never handing that coordinate space out at all.
public func highlightRanges(in text: String, query: String) -> [Range<String.Index>] {
    findOccurrences(body: text, query: query).compactMap { occurrence in
        guard let start = text.index(text.startIndex, offsetBy: occurrence.offset, limitedBy: text.endIndex),
            let end = text.index(start, offsetBy: occurrence.length, limitedBy: text.endIndex)
        else { return nil }
        return start..<end
    }
}
