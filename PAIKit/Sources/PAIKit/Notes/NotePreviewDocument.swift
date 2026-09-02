import Foundation
import Markdown

/// One item in ``NotePreviewDocument/items``: a top-level rendered block, or a resolved
/// attachment embed — both need to sit in the same ordered, line-addressable list, since a jump
/// target can land on either.
public enum NotePreviewItemKind: Sendable {
    case block(MarkdownBlock)
    case embed(target: String, alias: String?)
}

/// A rendered item plus the 1-based source line its markdown started at — how a jump lands on
/// the right item without reconstructing an exact character position inside rendered text (see
/// ``NotePreviewDocument/itemIndex(forCharacterOffset:in:)``).
public struct NotePreviewItem: Identifiable, Sendable {
    public let id: Int
    public let kind: NotePreviewItemKind
    public let startLine: Int
}

/// A note body parsed once for a read-only page: wikilinks resolved the same way
/// ``splitBodyForRender(_:nameToId:)`` resolves them, but kept as one line-addressable list of
/// top-level items instead of merged text segments — the shape a jump from the outline or from
/// in-note search needs to land on a specific block rather than only on the segment of text
/// surrounding it.
///
/// Built by splitting `body` at every embed the same way ``splitBodyForRender(_:nameToId:)``
/// does — never inside a combined re-parse of the whole document — so an embed becomes its own
/// item regardless of what markdown construct would otherwise have swallowed it: a list item it
/// lazily continues with no blank line between them, or a run of several embeds on consecutive
/// lines that would parse as one merged paragraph. Each surviving text segment is parsed on its
/// own and contributes one item per top-level block in it, rather than by slicing the whole
/// document's block list positionally against its child list — the two can disagree in length
/// (an empty paragraph node produces no ``MarkdownBlock`` at all), and a positional zip would
/// silently misalign every item after the gap rather than only the one that vanished.
public struct NotePreviewDocument: Sendable {
    public let items: [NotePreviewItem]

    public init(body: String, nameToId: [String: String]) {
        let links = findWikilinks(body)
        let chars = Array(body)

        var built: [NotePreviewItem] = []
        var textParts: [String] = []
        var textStartLine = 1
        var cursor = 0
        var line = 1

        func appendChunk(_ chunk: String) {
            if textParts.isEmpty { textStartLine = line }
            textParts.append(chunk)
        }

        func flushText() {
            guard !textParts.isEmpty else { return }
            let segment = textParts.joined()
            textParts = []
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let document = Document(parsing: segment, options: MarkdownParser.defaultOptions)
            for child in document.children {
                guard let block = MarkdownParser.parse(child.format(), options: MarkdownParser.defaultOptions).first
                else { continue }
                let localLine = child.range?.lowerBound.line ?? 1
                built.append(
                    NotePreviewItem(id: built.count, kind: .block(block), startLine: textStartLine + localLine - 1))
            }
        }

        for link in links {
            if link.start > cursor {
                let chunk = String(chars[cursor..<link.start])
                appendChunk(chunk)
                line += chunk.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            }
            if link.isEmbed {
                flushText()
                built.append(
                    NotePreviewItem(
                        id: built.count, kind: .embed(target: link.target, alias: link.alias), startLine: line))
            } else {
                // A wikilink's own source text never contains a newline (the grammar excludes it),
                // so it stays part of the segment currently accumulating rather than starting a
                // new one, and `line` needs no adjustment for it.
                appendChunk(Wikilinks.resolvedMarkdown(for: link, nameToId: nameToId))
            }
            cursor = link.end
        }
        if cursor < chars.count { appendChunk(String(chars[cursor...])) }
        flushText()

        items = built
    }

    /// The index into ``items`` a Character offset — from ``parseOutline(_:)`` or
    /// ``findOccurrences(body:query:)``, both counted against the same body this document was
    /// built from — falls in: the last item starting at or before that offset's line. `nil` only
    /// for an empty document.
    public func itemIndex(forCharacterOffset offset: Int, in body: String) -> Int? {
        guard !items.isEmpty else { return nil }
        let line = lineNumber(ofCharacterOffset: offset, in: body)
        var result = 0
        for (index, item) in items.enumerated() where item.startLine <= line {
            result = index
        }
        return result
    }
}

/// The 1-based source line a Character offset falls on — the same line-splitting convention
/// ``parseOutline(_:)`` and ``findOccurrences(body:query:)`` already count their own offsets in,
/// so an offset from either names the same line here as it does there.
public func lineNumber(ofCharacterOffset offset: Int, in body: String) -> Int {
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    var cursor = 0
    for (index, line) in lines.enumerated() {
        let end = cursor + line.count + 1  // +1 for the "\n" this split consumed
        if offset < end { return index + 1 }
        cursor = end
    }
    return max(lines.count, 1)
}
