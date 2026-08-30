import Foundation

/// The height of a rendered fenced code block — and, like ``MarkdownTableLayout``, deliberately
/// nothing about its width.
///
/// A code block does not wrap. It gets its own horizontal scroll container, mirroring the web
/// client, where every `<pre>` carries `overflow-x-auto` — otherwise a long line is cut off at the
/// bubble edge with no way to read the rest of it, which on a phone is most lines of most code.
///
/// That choice is what makes this arithmetic rather than a text layout, and the difference matters
/// more here than it looks: a measured height that disagrees with the drawn one moves every row
/// above the reader, and a wrapped code block's height depends on a TextKit pass this package
/// cannot run on Linux. Counting lines is exact, and it is exact at every width.
public enum MarkdownCodeBlockLayout {

    /// The number of visual lines a non-wrapping block occupies.
    ///
    /// A trailing newline does not add one — cmark keeps the fence's final line break in the
    /// block's text, so counting separators naively reports one phantom line per block, which is
    /// a gap under every code block in the transcript.
    public static func lineCount(of code: String) -> Int {
        var text = Substring(code)
        while text.last == "\n" || text.last == "\r" { text = text.dropLast() }
        guard !text.isEmpty else { return 1 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }

    /// `lineHeight` and `padding` are resolved by the caller; nothing here knows about
    /// typography, so the same formula serves the measurer and the view that draws the box.
    public static func height(for code: String, lineHeight: Double, padding: Double = 0) -> Double {
        Double(lineCount(of: code)) * lineHeight + 2 * padding
    }
}
