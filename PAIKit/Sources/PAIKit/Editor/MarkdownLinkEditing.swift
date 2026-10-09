import Foundation

/// What the link form opens with, and the range its result replaces — UTF-16 units, like every
/// range a text view speaks.
public struct MarkdownLinkDraft: Equatable, Sendable {
    public let text: String
    public let url: String
    public let range: NSRange

    public init(text: String, url: String, range: NSRange) {
        self.text = text
        self.url = url
        self.range = range
    }
}

/// The link button, as values: what the form prefills from the caret, and the edit its result
/// makes. Port of `pai-cloud/web/src/apps/notes/noteEditing.ts`'s `linkDraftAt` and
/// `formatMarkdownLink`; both suites carry the same cases so the two clients agree on what the
/// button does.
public enum MarkdownLinkEditing {

    private static let markdownLink = try! NSRegularExpression(
        pattern: #"(!?)\[([^\]\n]*)\]\(\s*(<[^>\n]*>|[^)\s]*)(?:\s+"[^"\n]*")?\s*\)"#)
    private static let bareUrl = try! NSRegularExpression(pattern: #"(?:https?://|www\.)[^\s<>()\[\]]+"#)
    /// A whole selection that reads as an address rather than as link text.
    private static let urlLike = try! NSRegularExpression(
        pattern: #"^(?:[a-z][a-z0-9+.-]*://|www\.|mailto:)\S+$"#, options: [.caseInsensitive])

    /// Prefills the form from where the selection is. A selection inside (or covering) an existing
    /// `[text](url)` edits that link in place; a caret on a bare URL edits that URL; otherwise a
    /// selected address becomes the URL and any other selection becomes the link text. Images
    /// (`![…](…)`) are left alone — the form would turn one into a link.
    public static func draft(in text: String, selection: NSRange) -> MarkdownLinkDraft {
        let source = text as NSString
        let selectionStart = min(max(selection.location, 0), source.length)
        let selectionEnd = min(max(selection.location + selection.length, selectionStart), source.length)

        var lineStart = selectionStart
        while lineStart > 0, source.character(at: lineStart - 1) != 0x0A { lineStart -= 1 }
        var lineEnd = selectionStart
        while lineEnd < source.length, source.character(at: lineEnd) != 0x0A { lineEnd += 1 }
        let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)
        let line = source.substring(with: lineRange)

        func within(_ range: NSRange) -> Bool {
            selectionStart >= range.location && min(selectionEnd, lineEnd) <= range.location + range.length
        }
        func absolute(_ range: NSRange) -> NSRange {
            NSRange(location: lineStart + range.location, length: range.length)
        }
        let lineNS = line as NSString
        let wholeLine = NSRange(location: 0, length: lineNS.length)

        for match in markdownLink.matches(in: line, range: wholeLine) {
            let range = absolute(match.range)
            if match.range(at: 1).length > 0 || !within(range) { continue }
            var url = lineNS.substring(with: match.range(at: 3))
            if url.hasPrefix("<") { url = String(url.dropFirst().dropLast()) }
            return MarkdownLinkDraft(text: lineNS.substring(with: match.range(at: 2)), url: url, range: range)
        }

        let caretOnly = NSRange(location: selectionStart, length: selectionEnd - selectionStart)
        if caretOnly.length == 0 {
            for match in bareUrl.matches(in: line, range: wholeLine) {
                let range = absolute(match.range)
                if within(range) {
                    return MarkdownLinkDraft(text: "", url: lineNS.substring(with: match.range), range: range)
                }
            }
            return MarkdownLinkDraft(text: "", url: "", range: caretOnly)
        }
        let selected = source.substring(with: caretOnly)
        let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
        let looksLikeUrl =
            urlLike.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) != nil
        return looksLikeUrl
            ? MarkdownLinkDraft(text: "", url: trimmed, range: caretOnly)
            : MarkdownLinkDraft(text: selected, url: "", range: caretOnly)
    }

    /// `[text](url)`; the URL stands in for empty text, and one holding a space or a parenthesis
    /// is wrapped in `<…>` so the link does not end early.
    public static func format(text: String, url: String) -> String {
        let needsBrackets =
            url.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || url.contains("(") || url.contains(")")
        let target = needsBrackets ? "<\(url)>" : url
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = (trimmed.isEmpty ? url : trimmed)
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(label)](\(target))"
    }

    /// The plain label a link unlinks to: its text with the `\\[`/`\\]` escapes ``format(text:url:)``
    /// writes undone, or the URL when the label is empty.
    public static func unlinkedLabel(of draft: MarkdownLinkDraft) -> String {
        let label = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\[", with: "[")
            .replacingOccurrences(of: "\\]", with: "]")
        return label.isEmpty ? draft.url : label
    }

    /// Replaces the whole `[text](url)` with just its label, caret after it. `nil` unless the draft
    /// is an existing markdown link — a bare URL or a new link has nothing to remove.
    public static func unlinkEdit(replacing draft: MarkdownLinkDraft, in text: String) -> MarkdownEdit? {
        guard isMarkdownLink(draft, in: text) else { return nil }
        let label = unlinkedLabel(of: draft)
        return MarkdownEdit(
            range: draft.range, replacement: label,
            selection: NSRange(location: draft.range.location + label.utf16.count, length: 0))
    }

    /// Whether the draft's range holds a `[text](url)` rather than a bare URL or an insertion
    /// point — what decides whether the form offers "Remove link".
    public static func isMarkdownLink(_ draft: MarkdownLinkDraft, in text: String) -> Bool {
        let source = text as NSString
        guard draft.range.length > 0, NSMaxRange(draft.range) <= source.length else { return false }
        let covered = source.substring(with: draft.range)
        let whole = NSRange(location: 0, length: (covered as NSString).length)
        guard let match = markdownLink.firstMatch(in: covered, range: whole) else { return false }
        return match.range == whole && match.range(at: 1).length == 0
    }

    /// Whether the form's address field holds something to link to — what OK waits for.
    public static func hasAddress(_ url: String?) -> Bool {
        !(url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Writes the form's result over the draft's range, with the caret after the link. `nil` when
    /// there is no address to link to.
    public static func edit(replacing draft: MarkdownLinkDraft, text: String, url: String) -> MarkdownEdit? {
        guard hasAddress(url) else { return nil }
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = format(text: text, url: address)
        return MarkdownEdit(
            range: draft.range, replacement: replacement,
            selection: NSRange(location: draft.range.location + replacement.utf16.count, length: 0))
    }
}
