import Foundation

/// The text form both halves of transcript search compare on.
///
/// Search has to run in two places that must agree: an index built over every message, including
/// the thousands not currently on screen, and a walk of what is actually rendered, which is the
/// only thing that can turn a hit into a range to highlight and scroll to. Both reduce text
/// through ``normalize(_:)``, so an occurrence counted by one is the same occurrence located by
/// the other.
///
/// Where the two could drift is markdown — the store holds source, the screen shows a rendering.
/// This client closes that gap completely rather than approximately, because
/// ``MarkdownBlock/plainText`` is derived from the same block model the renderer draws. The web
/// client reduces the source with regexes instead and documents the residue as deliberate slack.
public enum SearchText {

    /// Lowercased, with every run of whitespace collapsed to a single space.
    ///
    /// 🚨 The invariant this rests on: **one character in, at most one character out.** Length
    /// changes only by removing characters, never by adding one or replacing one with several,
    /// so a position in the normalized text can still be mapped back to the text it came from.
    /// A lowercase mapping that would grow a character therefore keeps the original — `İ`
    /// lowercases to two scalars in Unicode, and accepting that would silently break the
    /// mapping for every hit after it in the message.
    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false

        for character in text {
            if isSpace(character) {
                // Leading whitespace produces nothing, so the result never starts with a space;
                // a trailing run is never flushed, so it never ends with one either.
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(lowercasedPreservingLength(character))
        }

        return out
    }

    /// The same explicit set the web client uses, rather than Swift's `isWhitespace`.
    ///
    /// `isWhitespace` also covers non-breaking and ideographic spaces. Collapsing those would be
    /// defensible, but it would make the two clients disagree about what matches, and the
    /// reference implementation treats this set as a decision rather than an accident.
    static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\t" || character == "\n" || character == "\r"
            || character == "\u{0b}" || character == "\u{0c}"
    }

    /// Measured in UTF-16 units, not characters, because that is what the highlight ranges this
    /// feeds are measured in. `İ` is one character that lowercases to one character — an `i`
    /// carrying a combining dot — so a grapheme-level check would accept it and still shift
    /// every UTF-16 offset after it by one.
    private static func lowercasedPreservingLength(_ character: Character) -> Character {
        let lowered = character.lowercased()
        guard lowered.utf16.count == String(character).utf16.count,
            lowered.count == 1,
            let single = lowered.first
        else {
            return character
        }
        return single
    }

    /// Non-overlapping occurrences of `needle` in `haystack`. Both must already be normalized.
    public static func countMatches(haystack: String, needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }

        var count = 0
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex,
            let found = haystack.range(of: needle, range: searchStart..<haystack.endIndex)
        {
            count += 1
            searchStart = found.upperBound
        }
        return count
    }

    /// Whether raw text contains a raw query, normalizing both.
    public static func containsMatch(_ text: String, query: String) -> Bool {
        let needle = normalize(query)
        guard !needle.isEmpty else { return false }
        return normalize(text).contains(needle)
    }

    /// Every non-overlapping occurrence of `query` in `text`, in `text`'s own UTF-16 coordinates —
    /// not the normalized ones search matches against.
    ///
    /// A hit has to be located in the string a view actually draws, not the normalized one built
    /// only to compare against. This walks ``normalize(_:)``'s own per-character loop a second
    /// time, recording where each surviving character came from, then inverts a match found in
    /// the normalized text back through that table. It works because of the same invariant
    /// ``normalize(_:)`` documents: every surviving character keeps its exact UTF-16 width, so the
    /// two coordinate spaces only ever differ by whitespace *removed* between them, never by
    /// characters added, replaced or reordered.
    public static func findMatches(in text: String, query: String) -> [NSRange] {
        let needle = normalize(query)
        guard !needle.isEmpty else { return [] }

        var normalized = ""
        normalized.reserveCapacity(text.count)
        var sourceOffsets: [Int] = []
        sourceOffsets.reserveCapacity(text.utf16.count)
        var pendingSpace = false
        var sourceUTF16Offset = 0

        for character in text {
            let width = String(character).utf16.count
            if isSpace(character) {
                pendingSpace = !normalized.isEmpty
                sourceUTF16Offset += width
                continue
            }
            if pendingSpace {
                // The collapsed space's own recorded offset lands just past the whitespace run
                // rather than at its start — harmless, since a needle from `normalize(_:)` can
                // never itself start or end on a space, so this offset is never read as a match
                // boundary, only ever as an interior point between two real characters.
                normalized.append(" ")
                sourceOffsets.append(sourceUTF16Offset)
                pendingSpace = false
            }
            let mapped = lowercasedPreservingLength(character)
            normalized.append(mapped)
            for unit in 0..<width {
                sourceOffsets.append(sourceUTF16Offset + unit)
            }
            sourceUTF16Offset += width
        }

        var ranges: [NSRange] = []
        var searchStart = normalized.startIndex
        while searchStart < normalized.endIndex,
            let found = normalized.range(of: needle, range: searchStart..<normalized.endIndex)
        {
            let lowerUTF16 = found.lowerBound.utf16Offset(in: normalized)
            let upperUTF16 = found.upperBound.utf16Offset(in: normalized)
            let sourceStart = sourceOffsets[lowerUTF16]
            let sourceEnd = sourceOffsets[upperUTF16 - 1] + 1
            ranges.append(NSRange(location: sourceStart, length: sourceEnd - sourceStart))
            searchStart = found.upperBound
        }
        return ranges
    }
}
