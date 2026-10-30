import Foundation

/// How a ``BashEditDiff`` reads on screen, decided once for the row plan and the view.
public enum BashEditDiffDisplay {

    /// A body for one file: every line is `gutterWidth` characters of line number, one space, then
    /// the `- `/`+ ` prefix ``MessageDisplay/displayText(of:)`` gives an edit's diff, or two spaces
    /// for a line both sides share.
    public struct FileBody: Equatable, Sendable {
        public let text: String
        public let gutterWidth: Int
    }

    /// Whether the diff has anything to draw. A command that moved the whole tree has no diff by
    /// design, and flags with nothing to attach to are not worth a row.
    public static func isShown(_ diff: BashEditDiff) -> Bool {
        !diff.skipped && !(diff.files.isEmpty && diff.moreFiles == 0)
    }

    /// The one quiet line under the files, or `nil` when there is nothing to qualify.
    public static func note(for diff: BashEditDiff) -> String? {
        var parts: [String] = []
        if diff.moreFiles > 0 {
            parts.append("\(diff.moreFiles) more \(diff.moreFiles == 1 ? "file" : "files") changed")
        }
        if diff.unavailable { parts.append("part of the diff is unavailable") }
        if diff.shared { parts.append("another command ran here at the same time") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What happened to the file and by how many lines.
    public static func label(for file: BashEditDiffFile) -> String {
        var added = 0
        var removed = 0
        for line in file.hunks.flatMap(\.lines) {
            if line.hasPrefix("+") { added += 1 }
            if line.hasPrefix("-") { removed += 1 }
        }
        let verb = file.created == true ? "Created" : file.deleted == true ? "Deleted" : "Updated"
        return "\(verb) +\(added) -\(removed)"
    }

    /// The file's hunks as one numbered body. A removed line carries its number in the old file,
    /// every other line its number in the new one, so each number is where that line really is.
    public static func body(of file: BashEditDiffFile) -> FileBody {
        let lastLine = file.hunks.map { max($0.oldStart + $0.oldLines, $0.newStart + $0.newLines) }.max() ?? 0
        let gutterWidth = String(lastLine).count
        let gap = String(repeating: " ", count: gutterWidth + 1) + "⋯"

        var rows: [String] = []
        for (index, hunk) in file.hunks.enumerated() {
            if index > 0 { rows.append(gap) }
            var oldNumber = hunk.oldStart
            var newNumber = hunk.newStart
            for line in hunk.lines {
                let text = line.dropFirst()
                switch line.first {
                case "+":
                    rows.append("\(number(newNumber, gutterWidth)) + \(text)")
                    newNumber += 1
                case "-":
                    rows.append("\(number(oldNumber, gutterWidth)) - \(text)")
                    oldNumber += 1
                case " ":
                    rows.append("\(number(newNumber, gutterWidth))   \(text)")
                    oldNumber += 1
                    newNumber += 1
                default:
                    // git's "no newline at end of file" remark, which is about no line of the file.
                    break
                }
            }
        }
        return FileBody(text: rows.joined(separator: "\n"), gutterWidth: gutterWidth)
    }

    private static func number(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: " ", count: max(0, width - digits.count)) + digits
    }
}
