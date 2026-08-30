import Foundation

/// How much surrounding text an occurrence carries, on each side, for the "find in this note"
/// panel's context snippet.
private let noteSearchContextChars = 40

/// One occurrence of a search string within a note body — a Character offset to jump to, plus
/// enough surrounding text to preview the hit inline.
public struct NoteOccurrence: Equatable, Sendable, Identifiable {
    public let offset: Int
    public let context: String
    public let matchStart: Int
    public let matchEnd: Int
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
            NoteOccurrence(
                offset: at, context: String(bodyChars[start..<end]), matchStart: at - start,
                matchEnd: at - start + needleChars.count))
        from = at + needleChars.count
    }
    return occurrences
}

private func firstIndex(of needle: [Character], in haystack: [Character], from: Int) -> Int? {
    guard from <= haystack.count - needle.count else { return nil }
    for i in from...(haystack.count - needle.count) {
        if Array(haystack[i..<(i + needle.count)]) == needle { return i }
    }
    return nil
}
