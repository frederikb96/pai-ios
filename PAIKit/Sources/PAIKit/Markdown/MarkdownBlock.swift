import Foundation

/// One unit of layout in the transcript: a piece of a message whose height can be measured on
/// its own, before it is placed.
///
/// The transcript computes an exact height for every row up front and caches it, rather than
/// letting a cell discover its size while scrolling. That constraint is what shapes this model.
/// Anything whose extent is only known after an asynchronous load cannot be a block, which is
/// why there is no case for a remote image and no case that defers to a web view.
///
/// `Hashable` is load-bearing rather than incidental: a measured height is cached against the
/// block's hash, so two identical code blocks in different messages are measured once.
public enum MarkdownBlock: Hashable, Sendable {
    case paragraph(InlineText)
    case heading(level: Int, text: InlineText)
    /// Fenced or indented code. `language` is the info string as written, `nil` when absent.
    case codeBlock(language: String?, code: String)
    case blockQuote([MarkdownBlock])
    case list(MarkdownList)
    case table(MarkdownTable)
    case thematicBreak
    /// Raw HTML, kept verbatim as literal text.
    ///
    /// The web client renders nothing here — it does not enable `rehype-raw`, so an HTML node
    /// reaches no component and disappears. That is a side effect of its plugin set rather than
    /// a decision, and a transcript is a record: dropping a line of it because it happened to
    /// start with `<` is a defect. Showing the source is the honest degradation.
    ///
    /// A block that is nothing but an HTML comment never reaches this case at all —
    /// `MarkdownParser`'s `isHTMLCommentOnly` drops it, since a comment has no visible meaning
    /// in any HTML consumer and showing one as "source" would not be an honest degradation of
    /// anything a reader was meant to see.
    case htmlBlock(String)
}

extension MarkdownBlock {
    /// The visible text of this block — what a reader sees, and therefore what search matches.
    ///
    /// Derived from the block model rather than from the markdown source, so it *is* the
    /// rendering by construction. The web client approximates the same thing with regexes over
    /// the source and documents the leftover disagreement as deliberate slack; there is no
    /// leftover here, because there is nothing to approximate.
    public var plainText: String {
        switch self {
        case .paragraph(let text), .heading(_, let text):
            return text.plainText
        case .codeBlock(_, let code):
            return code
        case .htmlBlock(let raw):
            return raw
        case .thematicBreak:
            // A rule is a border, not text. Matching it would send search somewhere with
            // nothing to highlight.
            return ""
        case .blockQuote(let blocks):
            return blocks.plainText
        case .list(let list):
            return list.items.map(\.blocks.plainText).joined(separator: "\n")
        case .table(let table):
            return ([table.header] + table.rows)
                .map { row in row.map(\.plainText).joined(separator: " ") }
                .joined(separator: "\n")
        }
    }
}

extension [MarkdownBlock] {
    public var plainText: String {
        map(\.plainText).joined(separator: "\n")
    }
}

/// A run of inline content, already flattened out of the tree markdown parses into.
///
/// Nested emphasis inside a link inside a table cell is three levels deep and produces one
/// stretch of text on screen. Flattening at parse time makes measurement a single pass over an
/// array instead of a recursive walk, and it makes the parser's output something a test can read
/// without reconstructing a tree.
public struct InlineText: Hashable, Sendable {
    public let runs: [InlineRun]

    public init(runs: [InlineRun]) {
        self.runs = runs
    }

    /// The text with all styling removed — what search matches against and what a screen reader
    /// is given.
    public var plainText: String {
        runs.map(\.text).joined()
    }

    public var isEmpty: Bool {
        runs.allSatisfy { $0.text.isEmpty }
    }
}

/// A stretch of text carrying one combination of styles and at most one link.
public struct InlineRun: Hashable, Sendable {
    public let text: String
    public let style: InlineStyle
    /// The link destination exactly as written, or `nil`.
    ///
    /// Deliberately not a `URL`. Transcripts carry destinations `URL` rejects outright or
    /// silently rewrites, and losing one at parse time means losing the text the reader can see
    /// on screen. Deciding what is safe to open is the renderer's job, made once, at the point
    /// where a failure is visible.
    public let destination: String?

    public init(text: String, style: InlineStyle = [], destination: String? = nil) {
        self.text = text
        self.style = style
        self.destination = destination
    }
}

public struct InlineStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let bold = InlineStyle(rawValue: 1 << 0)
    public static let italic = InlineStyle(rawValue: 1 << 1)
    public static let strikethrough = InlineStyle(rawValue: 1 << 2)
    public static let code = InlineStyle(rawValue: 1 << 3)
}

public struct MarkdownList: Hashable, Sendable {
    public enum Marker: Hashable, Sendable {
        case bullet
        /// Ordered lists carry their first number, which GFM allows to be anything.
        case ordered(start: UInt)
    }

    public let marker: Marker
    public let items: [MarkdownListItem]

    public init(marker: Marker, items: [MarkdownListItem]) {
        self.marker = marker
        self.items = items
    }
}

public struct MarkdownListItem: Hashable, Sendable {
    public enum Checkbox: Hashable, Sendable {
        case unchecked
        case checked
    }

    /// Set only for GFM task-list items; `nil` for an ordinary one.
    public let checkbox: Checkbox?
    /// An item holds blocks, not text — a list item can contain a code block or a nested list.
    public let blocks: [MarkdownBlock]

    public init(checkbox: Checkbox? = nil, blocks: [MarkdownBlock]) {
        self.checkbox = checkbox
        self.blocks = blocks
    }
}

/// A GFM table, normalised to a rectangle.
///
/// Every row is padded or truncated to the same column count at parse time, so a renderer can
/// treat this as a grid and never has to decide what a short row means mid-layout. A ragged row
/// is the kind of input that produces an index crash in a measuring pass rather than a visible
/// mistake, so the shape is fixed once, here.
public struct MarkdownTable: Hashable, Sendable {
    public enum Alignment: Hashable, Sendable {
        case left
        case center
        case right
    }

    /// One entry per column; `nil` where the source specified no alignment.
    public let alignments: [Alignment?]
    public let header: [InlineText]
    public let rows: [[InlineText]]

    public init(alignments: [Alignment?], header: [InlineText], rows: [[InlineText]]) {
        self.alignments = alignments
        self.header = header
        self.rows = rows
    }

    public var columnCount: Int {
        header.count
    }
}
