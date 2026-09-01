import Foundation

/// A list line's hanging indent — how far a wrapped continuation should sit in from the margin,
/// so it lands under the item's own text rather than back at the left edge. Obsidian's own
/// behaviour for a wrapped bullet, which is what a note editor's gutter row asks both clients to
/// match.
///
/// A pass of its own rather than folded into `MarkdownSourceHighlighter`'s scan: colouring spans
/// and indenting paragraphs are different questions that happen to read the same source, and
/// each stays simpler answered on its own. Reuses `MarkdownListContinuation`'s own marker
/// parsing — the same "how wide is this line's prefix" question the Return-key handler already
/// answers, so a list item's hanging indent and its continuation marker can never disagree about
/// where the marker ends.
public struct MarkdownHangingIndent: Equatable, Sendable {
    /// UTF-16 offset where this logical line starts in the whole source, terminator included —
    /// the range an editor sets a paragraph style over.
    public let location: Int
    /// UTF-16 length of the whole line, terminator included.
    public let length: Int
    /// UTF-16 width of the marker prefix to hang from.
    public let markerWidth: Int

    public init(location: Int, length: Int, markerWidth: Int) {
        self.location = location
        self.length = length
        self.markerWidth = markerWidth
    }

    /// Every list line in `source` that wants a hanging indent — a bulleted, numbered or task
    /// item, at any nesting depth `MarkdownListContinuation` already understands. A line that is
    /// not a list item is simply absent from the result, rather than reported with a zero width.
    public static func indents(for source: String) -> [MarkdownHangingIndent] {
        guard !source.isEmpty else { return [] }
        var results: [MarkdownHangingIndent] = []
        var utf16Offset = 0
        for line in MarkdownLineSyntax.splitKeepingTerminators(source) {
            defer { utf16Offset += line.utf16.count }
            let content = line.prefix { !$0.isNewline }
            guard let prefixLength = MarkdownListContinuation.markerPrefixLength(ofLine: content), prefixLength > 0
            else { continue }
            results.append(
                MarkdownHangingIndent(location: utf16Offset, length: line.utf16.count, markerWidth: prefixLength))
        }
        return results
    }
}
