import Foundation

/// Where a full-text search hit's extract should be highlighted. `NoteSearchHit.extractOffsets`
/// carries only each match's START offset, not its length, so this highlights a fixed-length span
/// the same way the web's `HighlightedExtract` (`NoteList.tsx`) does: capped by the next offset or
/// the extract's own end.
///
/// Offsets arrive as CHARACTER positions — the backend counts Unicode codepoints — while an
/// `NSRange` (what everything that paints a `Text` from a highlight expects) measures in UTF-16.
/// This is the one place that bridges the two, the same bridging `SearchText` does for the
/// transcript's own search.
public enum NoteExtractHighlight {
    /// Matches the web's own constant in `HighlightedExtract` — the API gives no match length to
    /// be exact about, so both clients draw the same fixed-width guess.
    static let maxHighlightLength = 40

    /// Non-overlapping, ascending UTF-16 ranges within `extract` — one per offset that lands
    /// inside it. An offset the server reported outside the extract it also sent is silently
    /// dropped rather than thrown on: a server-side inconsistency this client cannot repair, and
    /// the rest of the extract should still render.
    public static func ranges(extract: String, offsets: [Int]) -> [NSRange] {
        guard !offsets.isEmpty else { return [] }
        let characterCount = extract.count
        let utf16OffsetByCharacterIndex = utf16Offsets(of: extract)

        var result: [NSRange] = []
        for (index, start) in offsets.enumerated() {
            guard start >= 0, start < characterCount else { continue }
            let nextOffset = index + 1 < offsets.count ? offsets[index + 1] : characterCount
            let end = min(start + maxHighlightLength, nextOffset, characterCount)
            guard end > start else { continue }
            let utf16Start = utf16OffsetByCharacterIndex[start]
            let utf16End = utf16OffsetByCharacterIndex[end]
            result.append(NSRange(location: utf16Start, length: utf16End - utf16Start))
        }
        return result
    }

    /// `result[i]` is where character index `i` begins in UTF-16 units; a trailing entry for
    /// `text.count` covers the end-of-string offset, so a caller can look up an end the same way
    /// it looks up a start.
    private static func utf16Offsets(of text: String) -> [Int] {
        var offsets: [Int] = []
        offsets.reserveCapacity(text.count + 1)
        var utf16Offset = 0
        for character in text {
            offsets.append(utf16Offset)
            utf16Offset += String(character).utf16.count
        }
        offsets.append(utf16Offset)
        return offsets
    }
}
