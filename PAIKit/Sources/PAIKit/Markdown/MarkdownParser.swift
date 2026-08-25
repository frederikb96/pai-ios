import Foundation
import Markdown

/// Turns a message's markdown into ``MarkdownBlock`` values.
///
/// The parse itself is Apple's cmark-gfm wrapper, so GFM tables, strikethrough, task lists and
/// autolinks are spec-correct rather than approximated. What this type adds is the conversion
/// into a model that can be measured: a flat run list per paragraph, a rectangular table, and no
/// node whose size depends on a network fetch.
///
/// Nothing here touches UIKit, which is the point — the decomposition is testable on any
/// platform, and only the measuring pass needs a device.
public enum MarkdownParser {

    /// Smart punctuation is **on** by default in swift-markdown: `--` becomes an en dash, `---`
    /// an em dash, and straight quotes curl.
    ///
    /// That default is wrong for this app specifically. A transcript is largely command lines,
    /// flags and quoted identifiers, and rewriting `--force` to `–force` corrupts the exact
    /// detail the reader opened the message to check — silently, and in a way that looks like
    /// the model wrote it that way. The web client applies no such substitution either.
    static let defaultOptions: ParseOptions = [.disableSmartOpts]

    public static func parse(_ source: String) -> [MarkdownBlock] {
        parse(source, options: defaultOptions)
    }

    /// Exposed so a test can parse the same source under different options and show that the
    /// option under test is the thing making the difference.
    static func parse(_ source: String, options: ParseOptions) -> [MarkdownBlock] {
        blocks(from: Document(parsing: source, options: options).children)
    }

    // MARK: - Blocks

    private static func blocks(from children: MarkupChildren) -> [MarkdownBlock] {
        children.compactMap(block(from:))
    }

    private static func block(from markup: Markup) -> MarkdownBlock? {
        switch markup {
        case let heading as Heading:
            return .heading(level: heading.level, text: inlineText(from: heading.children))

        case let paragraph as Paragraph:
            let text = inlineText(from: paragraph.children)
            return text.isEmpty ? nil : .paragraph(text)

        case let code as CodeBlock:
            let language = code.language.flatMap { $0.isEmpty ? nil : $0 }
            return .codeBlock(language: language, code: withoutTrailingNewline(code.code))

        case let quote as BlockQuote:
            return .blockQuote(blocks(from: quote.children))

        case let list as UnorderedList:
            return .list(MarkdownList(marker: .bullet, items: listItems(from: list.listItems)))

        case let list as OrderedList:
            return .list(MarkdownList(marker: .ordered(start: list.startIndex), items: listItems(from: list.listItems)))

        case let table as Table:
            return .table(convertTable(table))

        case is ThematicBreak:
            return .thematicBreak

        case let html as HTMLBlock:
            return .htmlBlock(withoutTrailingNewline(html.rawHTML))

        default:
            // Block directives, Doxygen commands and custom blocks are unreachable under the
            // options above. Falling through to the contained text means an unexpected node
            // loses its styling rather than its content.
            let text = inlineText(from: markup.children)
            return text.isEmpty ? nil : .paragraph(text)
        }
    }

    /// cmark terminates every code block and HTML block with a newline that is a delimiter
    /// rather than content. Keeping it would add an empty final line to the measured height of
    /// every code block in the transcript.
    private static func withoutTrailingNewline(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    // MARK: - Lists

    private static func listItems(from items: some Sequence<ListItem>) -> [MarkdownListItem] {
        items.map { item in
            MarkdownListItem(checkbox: checkbox(from: item.checkbox), blocks: blocks(from: item.children))
        }
    }

    private static func checkbox(from checkbox: Markdown.Checkbox?) -> MarkdownListItem.Checkbox? {
        switch checkbox {
        case .some(.checked): .checked
        case .some(.unchecked): .unchecked
        case .none: nil
        }
    }

    // MARK: - Tables

    private static func convertTable(_ table: Table) -> MarkdownTable {
        // `cells` and `rows` are lazy sequences, whose `map` stays lazy. Making each an array
        // first keeps the result a plain `[[InlineText]]` rather than nested lazy views.
        let alignments = table.columnAlignments.map(alignment(from:))
        let header = Array(table.head.cells).map { inlineText(from: $0.children) }
        let rows = Array(table.body.rows).map { row in
            Array(row.cells).map { inlineText(from: $0.children) }
        }

        // GFM decides a table's width from its delimiter row, but a malformed source can still
        // produce rows of differing length. One column count applied to every row means the
        // renderer indexes a grid it can trust.
        let columnCount = max(alignments.count, header.count, rows.map(\.count).max() ?? 0)
        let empty = InlineText(runs: [])

        return MarkdownTable(
            alignments: resized(alignments, to: columnCount, padding: nil),
            header: resized(header, to: columnCount, padding: empty),
            rows: rows.map { resized($0, to: columnCount, padding: empty) }
        )
    }

    private static func alignment(from alignment: Table.ColumnAlignment?) -> MarkdownTable.Alignment? {
        switch alignment {
        case .some(.left): .left
        case .some(.center): .center
        case .some(.right): .right
        case .none: nil
        }
    }

    private static func resized<Element>(_ values: [Element], to count: Int, padding: Element) -> [Element] {
        if values.count == count { return values }
        if values.count > count { return Array(values.prefix(count)) }
        return values + Array(repeating: padding, count: count - values.count)
    }

    // MARK: - Inline

    private static func inlineText(from children: MarkupChildren) -> InlineText {
        var runs: [InlineRun] = []
        appendRuns(from: children, style: [], destination: nil, into: &runs)
        return InlineText(runs: merged(runs))
    }

    private static func appendRuns(
        from children: MarkupChildren,
        style: InlineStyle,
        destination: String?,
        into runs: inout [InlineRun]
    ) {
        for child in children {
            switch child {
            case let text as Markdown.Text:
                runs.append(InlineRun(text: text.string, style: style, destination: destination))

            case let code as InlineCode:
                runs.append(InlineRun(text: code.code, style: style.union(.code), destination: destination))

            case is Emphasis:
                appendRuns(from: child.children, style: style.union(.italic), destination: destination, into: &runs)

            case is Strong:
                appendRuns(from: child.children, style: style.union(.bold), destination: destination, into: &runs)

            case is Strikethrough:
                appendRuns(
                    from: child.children,
                    style: style.union(.strikethrough),
                    destination: destination,
                    into: &runs
                )

            case let link as Link:
                // An outer link wins over an inner one: nesting is malformed, and the outer is
                // the one the reader's tap lands on.
                appendRuns(from: link.children, style: style, destination: destination ?? link.destination, into: &runs)

            case let image as Image:
                // An image cannot report a height without loading, and every row's height is
                // computed before anything reaches the screen. Showing the alt text as a link
                // keeps the reference readable and tappable instead of dropping it.
                let label = inlineText(from: image.children).plainText
                let shown = label.isEmpty ? (image.source ?? "") : label
                runs.append(InlineRun(text: shown, style: style, destination: destination ?? image.source))

            case is SoftBreak:
                // A newline inside a paragraph is a space, as in the web client — neither
                // enables the `breaks` behaviour that would turn it into a line break.
                runs.append(InlineRun(text: " ", style: style, destination: destination))

            case is LineBreak:
                runs.append(InlineRun(text: "\n", style: style, destination: destination))

            case let html as InlineHTML:
                runs.append(InlineRun(text: html.rawHTML, style: style, destination: destination))

            default:
                appendRuns(from: child.children, style: style, destination: destination, into: &runs)
            }
        }
    }

    /// Joins neighbouring runs that share styling, so `**bold `code`**` is not three runs where
    /// two would do. Measurement cost scales with run count, and a merged list is also what
    /// makes an expected value in a test readable.
    private static func merged(_ runs: [InlineRun]) -> [InlineRun] {
        runs.reduce(into: []) { result, run in
            guard !run.text.isEmpty else { return }
            if let last = result.last, last.style == run.style, last.destination == run.destination {
                result[result.count - 1] = InlineRun(
                    text: last.text + run.text,
                    style: last.style,
                    destination: last.destination
                )
            } else {
                result.append(run)
            }
        }
    }
}
