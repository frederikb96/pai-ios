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
public func findOccurrences(body: String, query: String) -> [NoteOccurrence] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return [] }
    let haystack = Array(body.lowercased())
    let needleChars = Array(needle.lowercased())
    guard !needleChars.isEmpty, needleChars.count <= haystack.count else { return [] }

    var occurrences: [NoteOccurrence] = []
    let bodyChars = Array(body)
    var from = 0
    while from <= haystack.count - needleChars.count {
        guard let at = firstIndex(of: needleChars, in: haystack, from: from) else { break }
        let start = max(0, at - noteSearchContextChars)
        let end = min(bodyChars.count, at + needleChars.count + noteSearchContextChars)
        occurrences.append(
            NoteOccurrence(offset: at, length: needleChars.count, context: String(bodyChars[start..<end])))
        from = at + needleChars.count
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

private func firstIndex(of needle: [Character], in haystack: [Character], from: Int) -> Int? {
    guard from <= haystack.count - needle.count else { return nil }
    for i in from...(haystack.count - needle.count) {
        if Array(haystack[i..<(i + needle.count)]) == needle { return i }
    }
    return nil
}
