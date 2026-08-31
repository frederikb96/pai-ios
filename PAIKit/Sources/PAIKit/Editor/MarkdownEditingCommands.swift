import Foundation

/// The formatting buttons above the keyboard, as values.
///
/// Each one is a pure function from (text, selection) to one replacement plus where the selection
/// ends up, so what a button does can be tested rather than tapped. The editor applies the result
/// through the text view's own edit path, which is what keeps Undo working — a button that
/// reassigns the whole string records one wholesale edit and Undo then throws away the paragraph.
public enum MarkdownCommand: String, Equatable, Sendable, CaseIterable {
    case heading
    case bold
    case italic
    case inlineCode
    case bulletList
    case checkbox
    case quote
    case link
    case indent
    case outdent
}

/// One replacement to make, in UTF-16 units, matching what a text view's `NSRange` speaks.
public struct MarkdownEdit: Equatable, Sendable {
    /// The range of the current text to replace.
    public let range: NSRange
    public let replacement: String
    /// Where the selection goes afterwards, absolute in the resulting text.
    public let selection: NSRange

    public init(range: NSRange, replacement: String, selection: NSRange) {
        self.range = range
        self.replacement = replacement
        self.selection = selection
    }
}

public enum MarkdownEditing {

    /// Heading levels the heading button walks through before returning to no heading at all.
    /// Deeper levels exist in markdown; a button that has to be pressed six times to get back to
    /// plain text does not.
    private static let headingCycle = ["# ", "## ", "### "]

    /// Task markers, in the order they must be tested: a plain `- ` is a prefix of all of them, so
    /// a shorter match found first would strip the dash and leave `[x] ` behind as text.
    private static let tasks = ["- [ ] ", "- [x] ", "- [X] "]

    public static func edit(_ command: MarkdownCommand, in text: String, selection: NSRange) -> MarkdownEdit? {
        let utf16 = Array(text.utf16)
        guard selection.location >= 0, selection.location + selection.length <= utf16.count else { return nil }
        switch command {
        case .bold: return wrap(text, selection, with: "**")
        case .italic: return wrap(text, selection, with: "*")
        case .inlineCode: return wrap(text, selection, with: "`")
        case .link: return link(text, selection)
        case .bulletList:
            return togglePrefix(
                text, selection, applied: ["- "], strippable: tasks + ["- ", "* ", "+ "], insert: "- ")
        case .checkbox:
            return togglePrefix(
                text, selection, applied: tasks, strippable: tasks + ["- ", "* ", "+ "], insert: "- [ ] ")
        case .quote:
            return togglePrefix(text, selection, applied: ["> "], strippable: ["> "], insert: "> ")
        case .heading: return cycleHeading(text, selection)
        case .indent: return indent(text, selection)
        case .outdent: return outdent(text, selection)
        }
    }

    // MARK: Inline

    /// Wrapping, or unwrapping when the selection is already wrapped — a second press of the same
    /// button has to undo the first, or bold becomes a one-way door.
    private static func wrap(_ text: String, _ selection: NSRange, with marker: String) -> MarkdownEdit {
        let utf16 = Array(text.utf16)
        let markerLength = marker.utf16.count
        let selected = string(utf16, selection)

        if selected.hasPrefix(marker), selected.hasSuffix(marker), selected.utf16.count >= 2 * markerLength {
            let inner = String(selected.dropFirst(marker.count).dropLast(marker.count))
            return MarkdownEdit(
                range: selection, replacement: inner,
                selection: NSRange(location: selection.location, length: inner.utf16.count))
        }

        let before = selection.location - markerLength
        let after = selection.location + selection.length
        if before >= 0, after + markerLength <= utf16.count,
            string(utf16, NSRange(location: before, length: markerLength)) == marker,
            string(utf16, NSRange(location: after, length: markerLength)) == marker
        {
            let outer = NSRange(location: before, length: selection.length + 2 * markerLength)
            return MarkdownEdit(
                range: outer, replacement: selected,
                selection: NSRange(location: before, length: selection.length))
        }

        return MarkdownEdit(
            range: selection, replacement: marker + selected + marker,
            selection: selection.length == 0
                ? NSRange(location: selection.location + markerLength, length: 0)
                : NSRange(location: selection.location + markerLength, length: selection.length))
    }

    /// `[selected](  )` with the caret between the brackets that still need filling in — the URL,
    /// or the text when nothing was selected.
    private static func link(_ text: String, _ selection: NSRange) -> MarkdownEdit {
        let selected = string(Array(text.utf16), selection)
        let replacement = "[\(selected)]()"
        let caret =
            selected.isEmpty
            ? selection.location + 1 : selection.location + replacement.utf16.count - 1
        return MarkdownEdit(
            range: selection, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    // MARK: Line-based

    /// Adds the prefix to every line the selection touches, or takes it off when every one of them
    /// already carries this exact marker.
    ///
    /// `applied` is what counts as "already done" and drives the toggle-off decision; `strippable`
    /// is the wider family that gets replaced rather than stacked on, which is what stops the
    /// checkbox button turning `- thing` into `- [ ] - thing`. A mixed selection gains the marker,
    /// so a second press on a half-formatted block finishes the job instead of undoing half of it.
    private static func togglePrefix(
        _ text: String, _ selection: NSRange, applied: [String], strippable: [String], insert: String
    ) -> MarkdownEdit? {
        let utf16 = Array(text.utf16)
        let span = lineSpan(utf16, selection)
        let block = string(utf16, span)
        let lines = block.components(separatedBy: "\n")
        let carried = lines.map { line -> (indent: String, rest: String, existing: String?) in
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            let rest = String(line.dropFirst(indent.count))
            return (indent, rest, strippable.first { rest.hasPrefix($0) })
        }
        guard !carried.isEmpty else { return nil }

        let removing = carried.allSatisfy { line in line.existing.map(applied.contains) ?? false }
        let rewritten = carried.map { line -> String in
            if removing, let existing = line.existing {
                return line.indent + String(line.rest.dropFirst(existing.count))
            }
            if let existing = line.existing {
                return line.indent + insert + String(line.rest.dropFirst(existing.count))
            }
            return line.indent + insert + line.rest
        }
        let replacement = rewritten.joined(separator: "\n")

        // Collapse to a caret the way `cycleHeading` does, rather than trying to preserve a
        // selection across markup that just changed shape: it keeps the content it was next to,
        // landing after a marker just added or replaced — which is what leaves the reader able to
        // keep typing instead of overwriting the very thing they just formatted.
        let firstLine = carried[0]
        let firstRewritten = rewritten[0]
        let localOld = selection.location - span.location
        let indentLength = firstLine.indent.utf16.count
        let local: Int
        if let existing = firstLine.existing {
            let existingLength = existing.utf16.count
            if localOld <= indentLength {
                local = localOld
            } else if localOld <= indentLength + existingLength {
                local = removing ? indentLength : indentLength + insert.utf16.count
            } else {
                local = localOld + (removing ? -existingLength : insert.utf16.count - existingLength)
            }
        } else {
            local = localOld < indentLength ? localOld : localOld + insert.utf16.count
        }
        let caret = span.location + min(max(local, 0), firstRewritten.utf16.count)
        return MarkdownEdit(range: span, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    // MARK: Indent / outdent

    /// A tab at the start of every line the selection touches — Freddy's own convention, matching
    /// the web editor (`noteEditing.ts`'s `indentLines`).
    private static func indent(_ text: String, _ selection: NSRange) -> MarkdownEdit {
        let utf16 = Array(text.utf16)
        let span = lineSpan(utf16, selection)
        let lines = string(utf16, span).components(separatedBy: "\n")
        let rewritten = lines.map { "\t" + $0 }
        let replacement = rewritten.joined(separator: "\n")

        guard selection.length == 0 else {
            // A real selection stays selected across the whole reindented block, matching the web
            // editor, so a second tap keeps indenting the same lines rather than needing a reselect.
            return MarkdownEdit(
                range: span, replacement: replacement,
                selection: NSRange(location: span.location, length: replacement.utf16.count))
        }
        // A caret shifts by the single tab inserted before its own line — `lineSpan` for an empty
        // selection always covers exactly that one line.
        let caret = span.location + (selection.location - span.location) + 1
        return MarkdownEdit(range: span, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// One level of indentation off every line the selection touches — a leading tab if there is
    /// one, otherwise up to four leading spaces (`noteEditing.ts`'s `outdentLines`). A line with
    /// neither is left alone rather than eating into its own content.
    private static func outdent(_ text: String, _ selection: NSRange) -> MarkdownEdit {
        let utf16 = Array(text.utf16)
        let span = lineSpan(utf16, selection)
        let lines = string(utf16, span).components(separatedBy: "\n")
        let removed: [Int] = lines.map { line in
            if line.hasPrefix("\t") { return 1 }
            return line.prefix(4).prefix { $0 == " " }.count
        }
        let rewritten = zip(lines, removed).map { line, count in String(line.dropFirst(count)) }
        let replacement = rewritten.joined(separator: "\n")

        guard selection.length == 0 else {
            return MarkdownEdit(
                range: span, replacement: replacement,
                selection: NSRange(location: span.location, length: replacement.utf16.count))
        }
        let localOld = selection.location - span.location
        let caret = span.location + max(localOld - removed[0], 0)
        return MarkdownEdit(range: span, replacement: replacement, selection: NSRange(location: caret, length: 0))
    }

    /// None → `#` → `##` → `###` → none, on the line the selection starts in.
    private static func cycleHeading(_ text: String, _ selection: NSRange) -> MarkdownEdit? {
        let utf16 = Array(text.utf16)
        let span = lineSpan(utf16, NSRange(location: selection.location, length: 0))
        let line = string(utf16, span)
        // Every ATX level is stripped, not only the three the button produces: a `####` typed by
        // hand or pasted in is a heading, and prepending to it makes `# #### Title`.
        let hashes = line.prefix { $0 == "#" }.count
        let isHeading = (1...6).contains(hashes) && line.dropFirst(hashes).first == " "
        let stripped = isHeading ? String(line.dropFirst(hashes + 1)) : line
        let current = isHeading ? headingCycle.firstIndex(where: { $0.count == hashes + 1 }) : nil
        let next = current.map { $0 + 1 } ?? (isHeading ? headingCycle.count : 0)
        let replacement = (next < headingCycle.count ? headingCycle[next] : "") + stripped
        let delta = replacement.utf16.count - line.utf16.count
        return MarkdownEdit(
            range: span, replacement: replacement,
            selection: NSRange(location: max(span.location, selection.location + delta), length: 0))
    }

    // MARK: Ranges

    /// The whole of every line the range touches, terminators excluded.
    private static func lineSpan(_ utf16: [UInt16], _ range: NSRange) -> NSRange {
        let newline = UInt16(UnicodeScalar("\n").value)
        var start = range.location
        while start > 0, utf16[start - 1] != newline { start -= 1 }
        var end = max(range.location + range.length, start)
        while end < utf16.count, utf16[end] != newline { end += 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func string(_ utf16: [UInt16], _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        return String(decoding: utf16[range.location..<(range.location + range.length)], as: UTF16.self)
    }
}
