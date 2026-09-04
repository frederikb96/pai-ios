import Foundation

/// Where one search hit sits inside a code block's own text — the line and column a vertical and
/// a horizontal reveal both need, neither of which a flat `NSRange` UTF-16 offset answers on its
/// own. A code block never wraps (this repo's own decided architecture — see
/// `MarkdownCodeBlockLayout`'s doc comment), so "line" here is exactly what
/// ``MarkdownCodeBlockLayout/lineCount(of:)`` counts: separated by the fence's own line breaks,
/// nothing else.
public enum CodeBlockHitGeometry {
    /// `line` and `column` are both 0-based, in UTF-16 units — the same coordinate system
    /// `NSRange` already uses, so a caller never converts between two different notions of "how
    /// far into the text". Reads `range.location` only: a search hit's own highlight is a single
    /// point to land on, not a span to fit on screen.
    public static func position(of range: NSRange, in code: String) -> (line: Int, column: Int) {
        let units = Array(code.utf16)
        let target = max(0, min(range.location, units.count))
        var line = 0
        var lineStart = 0
        for offset in 0..<target where units[offset] == 0x0A {
            line += 1
            lineStart = offset + 1
        }
        return (line, target - lineStart)
    }
}
