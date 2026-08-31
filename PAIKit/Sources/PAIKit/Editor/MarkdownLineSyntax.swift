import Foundation

/// Line-level markdown syntax the source highlighter has to recognise across a whole note in one
/// pass: where a fence opens and closes, and whether a line is a GFM table's delimiter row.
///
/// Kept separate from ``MarkdownSourceHighlighter`` because a fence's opener and closer are
/// matched across lines that may be far apart in the note, and testing that matching on its own
/// is easier without a whole scan pass built around it.
enum MarkdownLineSyntax {

    /// Splits into lines while keeping each line's terminator, so the pieces rejoin exactly —
    /// `components(separatedBy:)` and `split` both discard it, and `\r\n` has to survive intact:
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
    /// Every part of table-delimiter detection goes through this, and the strictness is the
    /// point. GFM does permit a table whose rows carry no outer pipes, but reading one costs far
    /// more than it buys: a paragraph mentioning `a | b` sitting above a `---` matches a pipeless
    /// delimiter row exactly, and dimming it as one would be a highlighting bug in ordinary prose.
    private static func beginsWithTablePipe(_ line: String) -> Bool {
        let body = line.drop { $0 == " " }
        guard line.count - body.count <= 3 else { return false }
        return body.first == "|"
    }

    /// The `| --- | :-: |` row. GFM requires it immediately under a table's header, but the
    /// highlighter has no reason to look for the header — dimming a delimiter row is correct
    /// whether or not the line above it happens to be one, and cheaper to check for on its own.
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
}
