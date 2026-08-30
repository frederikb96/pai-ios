import Foundation

/// A stretch of a note that shares one wrapping behaviour.
///
/// The editor is built from these rather than from one view per markdown block, and the
/// difference is the whole design. Freddy's requirement is that fenced code and tables scroll
/// sideways while everything else wraps — so the only boundaries that have to exist are the ones
/// *around* those two things. Prose in between stays a single editable region, which means
/// paragraph breaks, list continuation, word selection and every other editing behaviour inside
/// it is UIKit's rather than something reimplemented across a stack of views.
///
/// A typical note has one or two code blocks, so this produces a handful of regions where a
/// block-per-view editor would produce dozens — and cross-region editing, the part that is
/// genuinely hard, only has to work at those few seams.
public enum NoteSegmentKind: Equatable, Sendable, Hashable {
    /// Wraps. Everything that is not the two below.
    case prose
    /// A fenced code block, fences included. Does not wrap; scrolls sideways.
    case codeBlock
    /// A GFM table. Does not wrap; scrolls sideways.
    case table
}

/// One segment: its kind and the exact source it covers.
///
/// `text` is a verbatim slice, trailing newlines and all. That is what makes
/// ``NoteSegmentation/join(_:)`` byte-exact, and byte-exact is not a nicety here — these are
/// Freddy's real vault files, and an editor that silently normalises blank lines or trims
/// trailing whitespace rewrites notes that were never edited.
public struct NoteSegment: Equatable, Sendable, Hashable {
    public let kind: NoteSegmentKind
    public let text: String

    public init(kind: NoteSegmentKind, text: String) {
        self.kind = kind
        self.text = text
    }

    /// Whether this segment scrolls sideways instead of wrapping.
    public var isNoWrap: Bool { kind != .prose }

    /// The blank lines separating this segment from the one before it.
    ///
    /// A split puts the blank line after a code block at the *start* of the prose that follows,
    /// because that is where it is in the file. Shown as-is, the editor would open every region
    /// after a code block with an empty first line — so the view shows ``displayText`` and the
    /// separators are carried invisibly, which is also what keeps the file byte-exact.
    ///
    /// Newlines only. Leading spaces are indentation and belong to the content.
    public var leadingSeparator: String {
        String(text.prefix { $0 == "\n" || $0 == "\r" })
    }

    public var trailingSeparator: String {
        let body = text.dropFirst(leadingSeparator.count)
        return String(body.reversed().prefix { $0 == "\n" || $0 == "\r" }.reversed())
    }

    /// What the editor puts in front of the reader.
    public var displayText: String {
        let body = text.dropFirst(leadingSeparator.count)
        return String(body.dropLast(trailingSeparator.count))
    }

    /// Rebuild this segment from edited display text, putting the separators back.
    public func withDisplayText(_ newText: String) -> NoteSegment {
        NoteSegment(kind: kind, text: leadingSeparator + newText + trailingSeparator)
    }
}

/// Splitting a note into segments, and putting it back together.
public enum NoteSegmentation {

    /// Split a note body.
    ///
    /// Guarantees `join(split(source)) == source` for every input, which the tests check on
    /// awkward shapes rather than tidy ones — an unterminated fence, a table at EOF with no
    /// trailing newline, Windows line endings, an empty document.
    public static func split(_ source: String) -> [NoteSegment] {
        guard !source.isEmpty else { return [] }
        let lines = splitKeepingTerminators(source)
        var segments: [NoteSegment] = []
        var prose: [String] = []

        func flushProse() {
            guard !prose.isEmpty else { return }
            segments.append(NoteSegment(kind: .prose, text: prose.joined()))
            prose.removeAll()
        }

        var index = 0
        while index < lines.count {
            if let fence = openingFence(in: lines[index]) {
                flushProse()
                var body = [lines[index]]
                index += 1
                while index < lines.count {
                    let line = lines[index]
                    body.append(line)
                    index += 1
                    // The closing fence is part of the block. An unterminated one runs to the end
                    // of the document, which is what a renderer does with it too — treating it as
                    // prose instead would make the text jump between wrapping and not while it is
                    // being typed.
                    if closesFence(line, opener: fence) { break }
                }
                segments.append(NoteSegment(kind: .codeBlock, text: body.joined()))
                continue
            }

            if index + 1 < lines.count, isTableHeader(lines[index]), isTableDelimiter(lines[index + 1]) {
                flushProse()
                var body = [lines[index], lines[index + 1]]
                index += 2
                while index < lines.count, isTableRow(lines[index]) {
                    body.append(lines[index])
                    index += 1
                }
                segments.append(NoteSegment(kind: .table, text: body.joined()))
                continue
            }

            prose.append(lines[index])
            index += 1
        }
        flushProse()
        return segments
    }

    public static func join(_ segments: [NoteSegment]) -> String {
        segments.map(\.text).joined()
    }

    /// Replace one segment's text and re-split the result.
    ///
    /// Re-splitting rather than swapping in place is what makes the editor's structure follow the
    /// text instead of drifting from it: typing a fence turns a paragraph into a code block,
    /// deleting one turns it back, and neither needs a rule of its own. It also means an edit can
    /// merge two segments or split one, which is exactly what happens at the seams.
    public static func replacing(_ index: Int, with text: String, in segments: [NoteSegment]) -> [NoteSegment] {
        guard segments.indices.contains(index) else { return segments }
        var texts = segments.map(\.text)
        texts[index] = text
        return split(texts.joined())
    }

    // MARK: Line classification

    /// Splits into lines while keeping each line's terminator, so the pieces rejoin exactly.
    /// `components(separatedBy:)` and `split` both discard it, and `\r\n` has to survive intact —
    /// a note edited on a machine that uses it must not come back rewritten.
    static func splitKeepingTerminators(_ source: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var iterator = source.makeIterator()
        var pending: Character?
        while let character = pending ?? iterator.next() {
            pending = nil
            current.append(character)
            if character == "\r" {
                if let next = iterator.next() {
                    if next == "\n" {
                        current.append(next)
                    } else {
                        pending = next
                    }
                }
                lines.append(current)
                current = ""
            } else if character == "\n" {
                lines.append(current)
                current = ""
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// The fence that opens a code block on this line, if one does.
    ///
    /// Returns the run itself rather than a boolean because a closing fence must be at least as
    /// long and of the same character — CommonMark's rule, and the reason a block containing
    /// ```` ``` ```` inside a ```` ```` ```` fence stays one block.
    static func openingFence(in line: String) -> String? {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return nil }
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let run = body.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        // A backtick fence's info string may not contain a backtick — otherwise `` `a` `` in a
        // paragraph would open a block.
        if first == "`", body.dropFirst(run.count).contains("`") { return nil }
        return String(run)
    }

    static func closesFence(_ line: String, opener: String) -> Bool {
        guard let marker = opener.first else { return false }
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return false }
        let run = body.prefix { $0 == marker }
        guard run.count >= opener.count else { return false }
        // Nothing but whitespace may follow a closing fence.
        return body.dropFirst(run.count).allSatisfy { $0 == " " || $0 == "\n" || $0 == "\r" || $0 == "\t" }
    }

    /// Whether a line opens with a `|`, allowing the same three spaces of indentation every other
    /// block construct here allows.
    ///
    /// Every part of table detection goes through this, and the strictness is the point. GFM does
    /// permit a table whose rows carry no outer pipes, but reading one costs far more than it
    /// buys: a paragraph mentioning `a | b` sitting above a `---` matches a pipeless header and a
    /// pipeless delimiter exactly, and the paragraph then stops wrapping and becomes a sideways
    /// scroll box. Missing an outer-pipe-less table costs a table that wraps like prose — in a
    /// *source* editor, the same characters either way.
    static func beginsWithTablePipe(_ line: String) -> Bool {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return false }
        return body.first == "|"
    }

    static func isTableHeader(_ line: String) -> Bool {
        beginsWithTablePipe(line)
    }

    /// The `| --- | :-: |` row. GFM requires it immediately under the header, which is what makes
    /// a table detectable from two lines rather than from the whole paragraph.
    static func isTableDelimiter(_ line: String) -> Bool {
        guard beginsWithTablePipe(line) else { return false }
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("-") else { return false }
        guard trimmed.allSatisfy({ $0 == "|" || $0 == "-" || $0 == ":" || $0 == " " }) else { return false }
        let cells = trimmed.split(separator: "|", omittingEmptySubsequences: true)
        guard !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let body = cell.trimmingCharacters(in: .whitespaces)
            guard body.contains("-") else { return false }
            let stripped = body.drop { $0 == ":" }.reversed().drop { $0 == ":" }
            return !stripped.isEmpty && stripped.allSatisfy { $0 == "-" }
        }
    }

    static func isTableRow(_ line: String) -> Bool {
        beginsWithTablePipe(line)
    }
}
