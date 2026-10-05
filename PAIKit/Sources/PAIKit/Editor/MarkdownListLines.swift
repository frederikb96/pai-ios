import Foundation

/// The bullet and checkbox buttons, ported from the web editor's `noteEditing.ts`
/// (`toggleBulletLines` / `toggleCheckboxLine`) so both clients cycle a line identically.
///
/// - Bullet: when every touched line is a plain bullet the bullets come off; otherwise every line
///   becomes a bullet — a plain line gains `- `, a numbered line swaps its number for one, a task
///   line loses its box and keeps its marker, a bullet stays as it is.
/// - Checkbox: a cycle that never removes the task. The step is decided by the first non-blank
///   touched line and applied to all of them: no task → empty `[ ]`, empty → checked `[x]`,
///   checked → empty. A bullet keeps its marker and gains the box; a numbered line swaps its
///   number for `- [ ] `. Taking a task away is the bullet button's job.
///
/// Indentation, an existing marker character and the line's text are never rewritten. Blank lines
/// inside a multi-line selection are skipped; a caret on a single empty line is acted on, which
/// is how a list is started. The selection is carried across the edit rather than collapsed, so
/// pressing the button again acts on the same lines.
enum ListLines {

    /// One edit inside a single line, offsets in UTF-16 units relative to the line's start.
    private struct Splice {
        let at: Int
        let remove: Int
        let insert: String
    }

    private enum Kind {
        case plain, numbered, bullet, unchecked, checked
    }

    private static let space = UInt16(UnicodeScalar(" ").value)
    private static let tab = UInt16(UnicodeScalar("\t").value)
    private static let newline = UInt16(UnicodeScalar("\n").value)

    // MARK: Line parsing

    private static func indentLength(_ line: [UInt16]) -> Int {
        line.prefix { $0 == space || $0 == tab }.count
    }

    private static func isMarkerChar(_ unit: UInt16) -> Bool {
        unit == 0x2D || unit == 0x2A || unit == 0x2B  // - * +
    }

    private static func spaceRun(_ line: [UInt16], from: Int) -> Int {
        var end = from
        while end < line.count, line[end] == space { end += 1 }
        return end - from
    }

    /// Length of `^[ \t]*[-*+] +`, or nil.
    private static func bulletPrefix(_ line: [UInt16]) -> Int? {
        let indent = indentLength(line)
        guard indent < line.count, isMarkerChar(line[indent]) else { return nil }
        let gap = spaceRun(line, from: indent + 1)
        return gap > 0 ? indent + 1 + gap : nil
    }

    /// Length of `^[ \t]*\d+[.)] +`, or nil.
    private static func numberedPrefix(_ line: [UInt16]) -> Int? {
        let indent = indentLength(line)
        var i = indent
        while i < line.count, line[i] >= 0x30, line[i] <= 0x39 { i += 1 }
        guard i > indent, i < line.count, line[i] == 0x2E || line[i] == 0x29 else { return nil }
        let gap = spaceRun(line, from: i + 1)
        return gap > 0 ? i + 1 + gap : nil
    }

    /// The task's box state and full prefix length (`- [ ] `, with the spaces after the box), or
    /// nil. A box with no text after it is still a task; a box glued to text (`- [ ]x`) is not.
    private static func taskPrefix(_ line: [UInt16]) -> (checked: Bool, length: Int)? {
        guard let bullet = bulletPrefix(line), bullet + 3 <= line.count,
            line[bullet] == 0x5B, line[bullet + 2] == 0x5D
        else { return nil }
        let state = line[bullet + 1]
        guard state == space || state == 0x78 || state == 0x58 else { return nil }  // ' ' x X
        let after = bullet + 3
        let gap = spaceRun(line, from: after)
        guard gap > 0 || after == line.count else { return nil }
        return (state != space, after + gap)
    }

    private static func kind(_ line: [UInt16]) -> Kind {
        if let task = taskPrefix(line) { return task.checked ? .checked : .unchecked }
        if bulletPrefix(line) != nil { return .bullet }
        if numberedPrefix(line) != nil { return .numbered }
        return .plain
    }

    // MARK: Buttons

    static func toggleBullet(_ text: String, _ selection: NSRange) -> MarkdownEdit? {
        guard let target = targets(text, selection) else { return nil }
        let kinds = target.lines.map(kind)
        let considered = kinds.enumerated().filter { !target.skip[$0.offset] }.map(\.element)
        let removing = !considered.isEmpty && considered.allSatisfy { $0 == .bullet }
        var splices: [Splice?] = []
        for (i, line) in target.lines.enumerated() {
            if target.skip[i] {
                splices.append(nil)
            } else if removing {
                let indent = indentLength(line)
                splices.append(Splice(at: indent, remove: (bulletPrefix(line) ?? indent) - indent, insert: ""))
            } else {
                switch kinds[i] {
                case .bullet:
                    splices.append(nil)
                case .unchecked, .checked:
                    let prefix = bulletPrefix(line) ?? 0
                    let task = taskPrefix(line)?.length ?? prefix
                    splices.append(Splice(at: prefix, remove: task - prefix, insert: ""))
                case .plain, .numbered:
                    splices.append(markerSplice(line, kinds[i], "- "))
                }
            }
        }
        return apply(target, selection, splices)
    }

    static func toggleCheckbox(_ text: String, _ selection: NSRange) -> MarkdownEdit? {
        guard let target = targets(text, selection) else { return nil }
        let kinds = target.lines.map(kind)
        let lead = kinds.enumerated().first { !target.skip[$0.offset] }?.element
        let checking = lead == .unchecked
        let box = checking ? "x" : " "
        var splices: [Splice?] = []
        for (i, line) in target.lines.enumerated() {
            if target.skip[i] {
                splices.append(nil)
                continue
            }
            switch kinds[i] {
            case .unchecked, .checked:
                if (kinds[i] == .checked) == checking {
                    splices.append(nil)
                } else {
                    splices.append(Splice(at: (bulletPrefix(line) ?? 0) + 1, remove: 1, insert: box))
                }
            case .bullet:
                splices.append(Splice(at: bulletPrefix(line) ?? 0, remove: 0, insert: "[\(box)] "))
            case .plain, .numbered:
                splices.append(markerSplice(line, kinds[i], "- [\(box)] "))
            }
        }
        return apply(target, selection, splices)
    }

    /// Where a marker goes on a line and what it replaces: after the indentation, swapping a
    /// numbered line's own number out.
    private static func markerSplice(_ line: [UInt16], _ kind: Kind, _ marker: String) -> Splice {
        let indent = indentLength(line)
        if kind == .numbered, let numbered = numberedPrefix(line) {
            return Splice(at: indent, remove: numbered - indent, insert: marker)
        }
        return Splice(at: indent, remove: 0, insert: marker)
    }

    // MARK: Plumbing

    private struct Target {
        let span: NSRange
        let lines: [[UInt16]]
        let skip: [Bool]
    }

    /// The lines a list button acts on. A caret on an empty line still counts; blank lines inside
    /// a multi-line selection are left alone.
    private static func targets(_ text: String, _ selection: NSRange) -> Target? {
        let utf16 = Array(text.utf16)
        guard selection.location >= 0, selection.location + selection.length <= utf16.count else { return nil }
        var start = selection.location
        while start > 0, utf16[start - 1] != newline { start -= 1 }
        var end = max(selection.location + selection.length, start)
        while end < utf16.count, utf16[end] != newline { end += 1 }
        let block = Array(utf16[start..<end])
        let lines = block.split(separator: newline, omittingEmptySubsequences: false).map(Array.init)
        let skip = lines.map { line -> Bool in
            guard lines.count > 1 else { return false }
            return String(decoding: line, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return Target(span: NSRange(location: start, length: end - start), lines: lines, skip: skip)
    }

    /// Applies one splice per line (`nil` leaves the line alone) and carries the selection across.
    /// A caret sitting exactly where text is inserted moves to after it, so a fresh marker on an
    /// empty line leaves the caret ready to type; one inside removed text lands after the
    /// replacement.
    private static func apply(_ target: Target, _ selection: NSRange, _ splices: [Splice?]) -> MarkdownEdit {
        var absolute: [(at: Int, remove: Int, insertLength: Int)] = []
        var rewritten: [String] = []
        var offset = target.span.location
        for (i, line) in target.lines.enumerated() {
            if let splice = splices[i] {
                absolute.append((offset + splice.at, splice.remove, splice.insert.utf16.count))
                let head = String(decoding: line[..<splice.at], as: UTF16.self)
                let tail = String(decoding: line[(splice.at + splice.remove)...], as: UTF16.self)
                rewritten.append(head + splice.insert + tail)
            } else {
                rewritten.append(String(decoding: line, as: UTF16.self))
            }
            offset += line.count + 1
        }

        func map(_ position: Int) -> Int {
            var shifted = position
            for splice in absolute {
                if position < splice.at || (position == splice.at && splice.remove > 0) { break }
                if position >= splice.at + splice.remove {
                    shifted += splice.insertLength - splice.remove
                } else {
                    shifted = shifted - (position - splice.at) + splice.insertLength
                }
            }
            return shifted
        }

        let start = map(selection.location)
        let end = map(selection.location + selection.length)
        return MarkdownEdit(
            range: target.span, replacement: rewritten.joined(separator: "\n"),
            selection: NSRange(location: start, length: end - start))
    }
}
