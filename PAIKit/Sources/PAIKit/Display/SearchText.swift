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
}
