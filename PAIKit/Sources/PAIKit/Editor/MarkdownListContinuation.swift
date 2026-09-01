import Foundation

/// What Return should do when the caret is inside a list item.
///
/// A plain text view inserts a newline and nothing else, so the second bullet of every list has to
/// be typed by hand — including its indentation, which is what makes a nested list unusable on a
/// phone. This works out the marker to carry down, as a value, so the editor's own Return handler
/// stays three lines and the rules are testable without a device.
///
/// Deliberately not a markdown parser: only the line the caret is on matters, and the marker is
/// copied rather than interpreted. A `2.` under a `1.` is produced by counting up from the line
/// above, never by renumbering the list — rewriting numbers the reader did not touch is how an
/// editor loses an argument with someone who numbered their list `1.` all the way down on purpose.
public enum MarkdownListContinuation {

    /// What to do in place of the newline UIKit would have inserted.
    public struct Continuation: Equatable, Sendable {
        /// UTF-16 units immediately before the caret to remove first. Non-zero only when the item
        /// is empty and the marker is being taken away.
        public let deleteBefore: Int
        /// The text to insert. Empty when the marker is being taken away.
        public let insert: String

        public init(deleteBefore: Int, insert: String) {
            self.deleteBefore = deleteBefore
            self.insert = insert
        }
    }

    /// `nil` means "nothing special here" — the caller lets the text view insert its own newline.
    public static func onReturn(text: String, caretUtf16: Int) -> Continuation? {
        guard caretUtf16 >= 0, caretUtf16 <= text.utf16.count else { return nil }
        let caret = String.Index(utf16Offset: caretUtf16, in: text)
        let lineStart = lineStart(in: text, before: caret)
        guard let marker = Marker(line: text[lineStart...].prefix { $0 != "\n" }) else { return nil }

        // Before the marker ends, Return is an ordinary line break: the reader is splitting the
        // bullet itself, not asking for another one.
        let markerEnd = text.index(lineStart, offsetBy: marker.prefixLength)
        guard caret >= markerEnd else { return nil }

        guard !marker.contentIsEmpty else {
            // An empty item is how someone leaves a list. Taking the marker away leaves the caret
            // on a blank line, which is where the next paragraph starts.
            let prefix = text[lineStart..<markerEnd]
            return Continuation(deleteBefore: prefix.utf16.count, insert: "")
        }
        return Continuation(deleteBefore: 0, insert: "\n" + marker.next)
    }

    /// How wide `line`'s list marker is, in UTF-16 units — the same prefix `onReturn(text:
    /// caretUtf16:)` copies down to the next bullet, exposed on its own for a hanging indent to
    /// measure from. `nil` when the line is not a list item at all.
    ///
    /// UTF-16 width and `Character` count agree here without conversion: every character a
    /// marker can be made of — space, tab, a digit, `-`/`*`/`+`, `.`/`)`, `[`/`]`/`x`/`X` — is
    /// ASCII, and ASCII is one UTF-16 unit per character.
    public static func markerPrefixLength(ofLine line: Substring) -> Int? {
        Marker(line: line)?.prefixLength
    }

    private static func lineStart(in text: String, before caret: String.Index) -> String.Index {
        var index = caret
        while index > text.startIndex {
            let previous = text.index(before: index)
            if text[previous] == "\n" { return index }
            index = previous
        }
        return text.startIndex
    }

    /// One line's list marker, and what the line below it should open with.
    private struct Marker {
        let prefixLength: Int
        let next: String
        let contentIsEmpty: Bool

        init?(line: Substring) {
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let body = line.dropFirst(indent.count)
            guard let first = body.first else { return nil }

            if first == "-" || first == "*" || first == "+" {
                let after = body.dropFirst()
                guard let space = after.first, space == " " || space == "\t" else { return nil }
                let spacing = after.prefix { $0 == " " || $0 == "\t" }
                let rest = after.dropFirst(spacing.count)
                // A task item continues as an unchecked one. Copying `[x]` down would tick a box
                // for work nobody has done yet.
                let task = rest.hasPrefix("[ ] ") || rest.hasPrefix("[x] ") || rest.hasPrefix("[X] ")
                let content = task ? rest.dropFirst(4) : rest
                prefixLength = indent.count + 1 + spacing.count + (task ? 4 : 0)
                next = indent + String(first) + spacing + (task ? "[ ] " : "")
                contentIsEmpty = content.allSatisfy { $0 == " " || $0 == "\t" }
                return
            }

            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, let number = Int(digits) else { return nil }
            let afterDigits = body.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
            let after = afterDigits.dropFirst()
            guard let space = after.first, space == " " || space == "\t" else { return nil }
            let spacing = after.prefix { $0 == " " || $0 == "\t" }
            let content = after.dropFirst(spacing.count)
            prefixLength = indent.count + digits.count + 1 + spacing.count
            next = indent + String(number + 1) + String(delimiter) + spacing
            contentIsEmpty = content.allSatisfy { $0 == " " || $0 == "\t" }
        }
    }
}
