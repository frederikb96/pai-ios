import Foundation

/// Whether a caret sits inside a fenced code block — the editor needs this on its own, apart from
/// the highlighter's spans, to decide whether the formatting bar's markdown buttons apply.
/// Tapping Bold inside a code block would splice `**` into code rather than markup, and Return
/// there must not try to continue a markdown list that was never there.
public enum MarkdownFenceState {

    /// `caretUtf16` is an offset into `text`, matching what a text view's `selectedRange` speaks.
    public static func isInsideFence(text: String, caretUtf16: Int) -> Bool {
        let lines = MarkdownLineSyntax.splitKeepingTerminators(text)
        var consumed = 0
        var openFence: String?
        for line in lines {
            let lineLength = line.utf16.count
            if consumed + lineLength > caretUtf16 {
                // The caret's own line. A line that opens or closes a fence is markup, not
                // content, so the caret sitting on the fence itself still counts as "outside" —
                // only a fence already open coming into this line makes it code.
                return openFence != nil
            }
            if let fence = openFence {
                if MarkdownLineSyntax.closesFence(line, opener: fence) { openFence = nil }
            } else if let fence = MarkdownLineSyntax.openingFence(in: line) {
                openFence = fence
            }
            consumed += lineLength
        }
        return openFence != nil
    }
}
