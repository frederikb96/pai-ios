import Foundation

/// A real line-level diff, replacing the whole-block "glue one prefix onto the whole string"
/// shape both clients used to build an Edit's display text.
///
/// Neither client used to compute a diff at all — the display text was literally
/// `filePath + "\n- " + oldString + "\n+ " + newString`, one `-`/`+` glued onto each WHOLE
/// (possibly multi-line) string once. The web painted the whole old/new block a single colour
/// each, which stayed unambiguous; this app instead recoloured each line by its OWN prefix, so
/// only the first line of a multi-line block ever carried one and every continuation line fell
/// back to plain text. Building the display text from a real per-line diff fixes that by
/// construction: every line gets its own `- `/`+ ` (or no prefix, for an unchanged line shared
/// by both sides), so the existing per-line colouring in `ToolBodyColorHint.diff` already works.
///
/// Built on Foundation's `CollectionDifference` — no new dependency, and Linux-testable like
/// everything else in this layer.
public enum EditDiff {

    /// One line of a line-level diff. `.context` is a line shared by both sides, shown once
    /// rather than duplicated under both a `-` and a `+`.
    public enum Line: Equatable, Sendable {
        case context(String)
        case removed(String)
        case added(String)
    }

    /// Diffs `old` against `new`, line by line.
    ///
    /// A `CollectionDifference` names removals by their offset in `old` and insertions by their
    /// offset in `new`; unchanged elements keep their relative order in both. Walking both arrays
    /// with one cursor each, always preferring a pending removal at the current old cursor before
    /// a pending insertion at the current new cursor, reconstructs the conventional unified-diff
    /// shape — every removed line of a changed block ahead of every added line of it — without a
    /// second pass.
    public static func lines(old: String, new: String) -> [Line] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        var result: [Line] = []
        var oldIndex = 0
        var newIndex = 0
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                result.append(.removed(oldLines[oldIndex]))
                oldIndex += 1
            } else if newIndex < newLines.count, insertedOffsets.contains(newIndex) {
                result.append(.added(newLines[newIndex]))
                newIndex += 1
            } else if oldIndex < oldLines.count, newIndex < newLines.count {
                result.append(.context(oldLines[oldIndex]))
                oldIndex += 1
                newIndex += 1
            } else {
                // Only one side has lines left and neither set claims the remaining offset —
                // unreachable given `CollectionDifference`'s own guarantee, but a defined
                // fallback rather than an infinite loop if that guarantee is ever violated.
                break
            }
        }
        return result
    }

    /// A run of consecutive `.removed` lines immediately followed by a run of the same length of
    /// consecutive `.added` lines — a "this line changed" pair, as opposed to a pure deletion or
    /// a pure addition. Only equal-length runs pair index-for-index; a run of different lengths
    /// is a real restructuring, not a small in-place edit, and is left as plain removed/added
    /// lines with no word-level highlight.
    public static func changedLinePairs(in lines: [Line]) -> [(removedIndex: Int, addedIndex: Int)] {
        var pairs: [(removedIndex: Int, addedIndex: Int)] = []
        var index = 0
        while index < lines.count {
            guard case .removed = lines[index] else {
                index += 1
                continue
            }
            var removedEnd = index
            while removedEnd + 1 < lines.count, case .removed = lines[removedEnd + 1] { removedEnd += 1 }
            var addedEnd = removedEnd
            while addedEnd + 1 < lines.count, case .added = lines[addedEnd + 1] { addedEnd += 1 }
            let removedCount = removedEnd - index + 1
            let addedCount = addedEnd - removedEnd
            if removedCount == addedCount {
                for offset in 0..<removedCount {
                    pairs.append((removedIndex: index + offset, addedIndex: removedEnd + 1 + offset))
                }
            }
            index = addedEnd + 1
        }
        return pairs
    }

    /// One token of a word-level diff — a run of non-whitespace, or a run of whitespace, tagged
    /// with whether it is part of the change. Splitting whitespace into its own tokens (rather
    /// than folding it into a word) keeps re-joining exact and keeps a pure whitespace change
    /// (trailing spaces, a re-indent) visible as one.
    public struct WordToken: Equatable, Sendable {
        public let text: String
        public let changed: Bool
    }

    /// Tokenizes one line into alternating whitespace/non-whitespace runs, for `wordDiff` below.
    public static func tokenize(_ line: String) -> [String] {
        guard !line.isEmpty else { return [] }
        var tokens: [String] = []
        var current = ""
        var currentIsSpace: Bool?
        for character in line {
            let isSpace = character.isWhitespace
            if currentIsSpace == nil || currentIsSpace == isSpace {
                current.append(character)
            } else {
                tokens.append(current)
                current = String(character)
            }
            currentIsSpace = isSpace
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// A word-level diff between one changed line's old and new text — the pass the row asks for
    /// "inside changed lines," on top of the line-level diff above. Pure text in, tagged tokens
    /// out; drawing the tags as a background tint is the caller's job, since it never changes
    /// line count or content length and so never affects a row's measured height.
    public static func wordDiff(removed: String, added: String) -> (removed: [WordToken], added: [WordToken]) {
        let removedTokens = tokenize(removed)
        let addedTokens = tokenize(added)
        let diff = addedTokens.difference(from: removedTokens)

        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removedOffsets.insert(offset)
            case .insert(let offset, _, _): insertedOffsets.insert(offset)
            }
        }

        let removedResult = removedTokens.enumerated().map { WordToken(text: $1, changed: removedOffsets.contains($0)) }
        let addedResult = addedTokens.enumerated().map { WordToken(text: $1, changed: insertedOffsets.contains($0)) }
        return (removed: removedResult, added: addedResult)
    }
}
