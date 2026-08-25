import Foundation

/// Bash output in a transcript arrives with its terminal colouring intact.
public enum Ansi {

    public static func hasEscapes(_ text: String) -> Bool {
        text.contains("\u{1b}")
    }

    /// Removes SGR-style escape sequences, leaving the text they were colouring.
    ///
    /// Deliberately the same narrow pattern the web client strips — `ESC [ … letter` — rather
    /// than every sequence a terminal can emit. Widening it here without widening it there
    /// would make the two clients disagree about what a message contains, and search is built
    /// from displayed text.
    public static func strip(_ text: String) -> String {
        guard hasEscapes(text) else { return text }

        var result = ""
        result.reserveCapacity(text.count)
        var rest = Substring(text)

        while let escape = rest.firstIndex(of: "\u{1b}") {
            result += rest[rest.startIndex..<escape]
            let afterEscape = rest.index(after: escape)

            guard afterEscape < rest.endIndex, rest[afterEscape] == "[" else {
                // A lone ESC, or one starting a sequence this does not handle: keep it as text
                // rather than swallowing the character after it.
                result.append(rest[escape])
                rest = rest[afterEscape...]
                continue
            }

            // ASCII-only, matching the web's `[0-9;]*[a-zA-Z]`. Swift's `isNumber`/`isLetter`
            // also accept superscripts, Devanagari digits and the like, which would let this
            // consume real content that merely follows an escape character.
            var cursor = rest.index(after: afterEscape)
            while cursor < rest.endIndex, rest[cursor].isASCII, rest[cursor].isNumber || rest[cursor] == ";" {
                cursor = rest.index(after: cursor)
            }

            guard cursor < rest.endIndex, rest[cursor].isASCII, rest[cursor].isLetter else {
                result.append(rest[escape])
                rest = rest[afterEscape...]
                continue
            }

            rest = rest[rest.index(after: cursor)...]
        }

        return result + rest
    }
}
