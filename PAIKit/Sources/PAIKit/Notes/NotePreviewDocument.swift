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
/// ``splitBodyForRender(_:nameToId:)`` resolves them for the editor's own quick-preview sheet, but
/// kept as one line-addressable list of top-level items instead of merged text segments — the
/// shape a jump from the outline or from in-note search needs to land on a specific block rather
/// than only on the segment of text surrounding it.
///
/// Each item is parsed independently from its own formatted source (`Markup/format()`) rather
/// than by slicing the whole document's block list positionally against its child list — the two
/// can disagree in length (an empty paragraph node produces no ``MarkdownBlock`` at all), and a
/// positional zip would silently misalign every item after the gap rather than only the one that
/// vanished.
public struct NotePreviewDocument: Sendable {
    public let items: [NotePreviewItem]

    public init(body: String, nameToId: [String: String]) {
        let (rewritten, embedByPlaceholder) = Self.rewrite(body, nameToId: nameToId)
        let document = Document(parsing: rewritten, options: MarkdownParser.defaultOptions)

        var built: [NotePreviewItem] = []
        for child in document.children {
            guard let block = MarkdownParser.parse(child.format(), options: MarkdownParser.defaultOptions).first
            else { continue }
            let startLine = child.range?.lowerBound.line ?? 1
            if case .paragraph(let text) = block,
                let embed = embedByPlaceholder[text.plainText.trimmingCharacters(in: .whitespaces)]
            {
                built.append(
                    NotePreviewItem(
                        id: built.count, kind: .embed(target: embed.target, alias: embed.alias), startLine: startLine))
            } else {
                built.append(NotePreviewItem(id: built.count, kind: .block(block), startLine: startLine))
            }
        }
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

    /// Replaces every wikilink in `body` in place — a resolved note link or a strikethrough for a
    /// dead one, exactly as ``splitBodyForRender(_:nameToId:)`` does — except an embed, which
    /// becomes a unique placeholder token instead of disappearing from the text stream. None of
    /// the three replacements can contain a newline, so every surviving line keeps its own line
    /// number and the source line ``Markup/range`` reports downstream still names the same
    /// position in the original `body`.
    private static func rewrite(
        _ body: String, nameToId: [String: String]
    ) -> (rewritten: String, embedByPlaceholder: [String: (target: String, alias: String?)]) {
        let links = findWikilinks(body)
        guard !links.isEmpty else { return (body, [:]) }

        let chars = Array(body)
        var rewritten = ""
        rewritten.reserveCapacity(chars.count)
        var embedByPlaceholder: [String: (target: String, alias: String?)] = [:]
        var cursor = 0

        for link in links {
            if link.start > cursor { rewritten += String(chars[cursor..<link.start]) }
            if link.isEmbed {
                let placeholder = "\u{FFFC}note-embed-\(embedByPlaceholder.count)\u{FFFC}"
                embedByPlaceholder[placeholder] = (link.target, link.alias)
                rewritten += placeholder
            } else {
                let display = Wikilinks.escapeMarkdownText(link.alias ?? link.target)
                let basename =
                    link.target.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init)
                    ?? link.target
                if let resolvedId = nameToId[basename.lowercased()] {
                    rewritten += "[\(display)](\(noteLinkURL(id: resolvedId)))"
                } else {
                    rewritten += "~~\(display)~~"
                }
            }
            cursor = link.end
        }
        if cursor < chars.count { rewritten += String(chars[cursor...]) }
        return (rewritten, embedByPlaceholder)
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
