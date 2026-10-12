import Foundation
import Markdown

/// A top-level rendered block plus the 1-based source line its markdown started at — how a jump
/// lands on the right item without reconstructing an exact character position inside rendered
/// text (see ``NotePreviewDocument/itemIndex(forCharacterOffset:in:)``).
public struct NotePreviewItem: Identifiable, Sendable {
    public let id: Int
    public let block: MarkdownBlock
    public let startLine: Int
    /// The ordinal of the first task box this item draws, counting every box on the page in
    /// drawing order — an index into ``NotePreviewDocument/taskMarks``.
    public let firstTask: Int
}

/// An attachment drawn where the note wrote it: an embed (`![[...]]`), or a plain wikilink that
/// resolved to an attachment rather than a note.
public struct NotePreviewAttachment: Hashable, Sendable {
    /// `.embed` shows an image in place; `.link` is a reference to the file and always a chip,
    /// image or not, mirroring the web's `NoteAttachmentEmbed` `mode` prop.
    public enum Mode: Hashable, Sendable {
        case embed
        case link
    }

    public let target: String
    public let mode: Mode
    /// What the link called the file; a chip shows it in place of the stored name.
    public let label: String?

    public init(target: String, mode: Mode, label: String? = nil) {
        self.target = target
        self.mode = mode
        self.label = label
    }
}

/// A note body parsed once for a read-only page: wikilinks resolved by
/// ``splitBodyForRender(_:nameToId:attachmentIndex:selfName:)``, kept as one line-addressable list
/// of top-level items — the shape a jump from the outline or from in-note search needs to land on
/// a specific block.
///
/// Each attachment is written back into the markdown where it stood, as a link to
/// ``NotePreviewInline/attachmentScheme`` naming its index in ``attachments``, and the whole body
/// is parsed in one pass. An attachment inside a list item therefore stays inside that item, and
/// the rest of the list stays a list: parsing the text after an attachment on its own would read
/// an indented next item as a code block. The renderer finds the placeholder in a block's inline
/// text (``NotePreviewInline/lines(of:attachments:drawsAsBlock:)``) and draws the attachment there.
/// No rewrite introduces a newline, so a block's source line in the rewritten text is its line in
/// `body`.
public struct NotePreviewDocument: Sendable {
    public let items: [NotePreviewItem]
    /// Every attachment the body draws, indexed by the placeholder links in ``items``.
    public let attachments: [NotePreviewAttachment]
    /// Where each drawn task box lives in the body, by the ordinal it is drawn in; empty when the
    /// body's own parse and the drawn page do not agree on every box, which makes nothing
    /// tickable (see ``NoteTasks``).
    public let taskMarks: [NoteTaskMark]

    public init(
        body: String, nameToId: [String: String], attachmentIndex: AttachmentIndex = .empty,
        selfName: String? = nil
    ) {
        var markdown = ""
        var found: [NotePreviewAttachment] = []
        for segment in splitBodyForRender(
            body, nameToId: nameToId, attachmentIndex: attachmentIndex, selfName: selfName)
        {
            let attachment: NotePreviewAttachment
            switch segment {
            case .text(let text):
                markdown += text
                continue
            case .embed(let target, _):
                attachment = NotePreviewAttachment(target: target, mode: .embed)
            case .attachmentLink(let relPath, let label):
                attachment = NotePreviewAttachment(target: relPath, mode: .link, label: label)
            }
            markdown += NotePreviewInline.placeholder(for: attachment, index: found.count)
            found.append(attachment)
        }

        // One item per top-level child that converts to a block, each carrying its own line: an
        // empty paragraph converts to nothing, and only that child goes missing.
        var built: [NotePreviewItem] = []
        var drawn: [Bool] = []
        let document = Document(parsing: markdown, options: MarkdownParser.defaultOptions)
        for child in document.children {
            guard let block = MarkdownParser.block(from: child) else { continue }
            built.append(
                NotePreviewItem(
                    id: built.count, block: block, startLine: child.range?.lowerBound.line ?? 1,
                    firstTask: drawn.count))
            drawn += NoteTasks.drawnStates(in: [block])
        }
        items = built
        attachments = found
        taskMarks = NoteTasks.marks(in: body, drawn: drawn)
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

/// One stretch of a block's inline content once its attachments are taken out: text, or the
/// attachment a placeholder link named.
public enum NotePreviewInline: Hashable, Sendable {
    case text(InlineText)
    case attachment(NotePreviewAttachment)

    /// The link scheme a placeholder carries, followed by the attachment's index.
    public static let attachmentScheme = "pai-attachment://"

    /// The markdown written where an attachment stood. The label is the file's name, so a place
    /// that shows a block as plain text (a table cell) reads the name rather than the
    /// placeholder.
    static func placeholder(for attachment: NotePreviewAttachment, index: Int) -> String {
        let name =
            attachment.label ?? attachment.target.split(separator: "/").last.map(String.init) ?? attachment.target
        return "[\(Wikilinks.escapeMarkdownText(name))](\(attachmentScheme)\(index))"
    }

    /// One row of a block's content, top to bottom: an attachment drawn as a block of its own (an
    /// image), or a run of text and chips that flows like a line of text.
    public enum Line: Hashable, Sendable {
        case block(NotePreviewAttachment)
        case flow([NotePreviewInline])
    }

    /// `text` split at its placeholder links, or `nil` when it carries none and draws as plain
    /// text. `drawsAsBlock` decides which attachments take a row of their own. Text beside an
    /// attachment loses the whitespace and line breaks at its edges, since the attachment
    /// between them already separates the two.
    public static func lines(
        of text: InlineText, attachments: [NotePreviewAttachment],
        drawsAsBlock: (NotePreviewAttachment) -> Bool
    ) -> [Line]? {
        var lines: [Line] = []
        var flow: [NotePreviewInline] = []
        var runs: [InlineRun] = []
        var sawAttachment = false

        func flushRuns() {
            if let trimmed = trimmed(runs) { flow.append(.text(trimmed)) }
            runs = []
        }
        func flushFlow() {
            flushRuns()
            if !flow.isEmpty { lines.append(.flow(flow)) }
            flow = []
        }

        for run in text.runs {
            guard let attachment = attachment(named: run.destination, in: attachments) else {
                runs.append(run)
                continue
            }
            sawAttachment = true
            if drawsAsBlock(attachment) {
                flushFlow()
                lines.append(.block(attachment))
            } else {
                flushRuns()
                flow.append(.attachment(attachment))
            }
        }
        guard sawAttachment else { return nil }
        flushFlow()
        return lines
    }

    private static func attachment(named destination: String?, in attachments: [NotePreviewAttachment])
        -> NotePreviewAttachment?
    {
        guard let destination, destination.hasPrefix(attachmentScheme),
            let index = Int(destination.dropFirst(attachmentScheme.count)), attachments.indices.contains(index)
        else { return nil }
        return attachments[index]
    }

    /// `runs` without leading and trailing whitespace, or `nil` when nothing else is left.
    private static func trimmed(_ runs: [InlineRun]) -> InlineText? {
        var runs = runs
        while let first = runs.first {
            let text = String(first.text.drop(while: \.isWhitespace))
            if !text.isEmpty {
                runs[0] = InlineRun(text: text, style: first.style, destination: first.destination)
                break
            }
            runs.removeFirst()
        }
        while let last = runs.last {
            var text = last.text
            while text.last?.isWhitespace == true { text.removeLast() }
            if !text.isEmpty {
                runs[runs.count - 1] = InlineRun(text: text, style: last.style, destination: last.destination)
                break
            }
            runs.removeLast()
        }
        return runs.isEmpty ? nil : InlineText(runs: runs)
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
