import Foundation
import Markdown

/// Turns a message's markdown into ``MarkdownBlock`` values.
///
/// The parse itself is Apple's cmark-gfm wrapper, so GFM tables, strikethrough and task lists are
/// spec-correct rather than approximated — the syntax extensions cmark-gfm attaches for those
/// (`CommonMarkConverter.swift`) do not include the "autolink" extension, though, so a bare
/// `https://…` still parses as ordinary text on its own; ``autolinkedRuns(in:style:)`` is the
/// second pass that catches it. Otherwise, what this type adds is the conversion into a model
/// that can be measured: a flat run list per paragraph, a rectangular table, and no node whose
/// size depends on a network fetch.
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
                // GFM tables, strikethrough and task lists are attached to the underlying cmark
                // parser as syntax extensions (`CommonMarkConverter.swift`); the GFM "autolink"
                // extension — the one that would turn a bare `https://…` into a link on its own —
                // is not. So a plain `Markdown.Text` node here can genuinely contain a URL that
                // parsed as nothing but text, and this is where that gets a second look. Skipped
                // when `destination` is already set: that text is already the label of a real
                // markdown link (or an image's alt text), and re-splitting it would only ever
                // shorten the tappable region, never usefully change it.
                runs.append(
                    contentsOf: destination == nil
                        ? autolinkedRuns(in: text.string, style: style)
                        : [InlineRun(text: text.string, style: style, destination: destination)])

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

    /// GFM's "extended autolink" grammar (the same one `remark-gfm` applies on the web side of
    /// this rule, confirmed against its own rendering rather than assumed): `http://`/`https://`,
    /// or a bare `www.` domain not preceded by a word character or another `.` — matched greedily
    /// through non-whitespace, then narrowed by ``trimTrailingPunctuation(from:in:)`` below. A
    /// `www.` match's destination gets an implicit `http://` prefix, same as GFM specifies; the
    /// visible label stays the `www…` text exactly as written. Nothing about the START of a match
    /// is trimmed either way; a scheme or `www.` is unambiguous. Not fenced-code-aware by
    /// construction: this only ever runs against a `Markdown.Text` node, and cmark already routes
    /// a fenced or inline code span's content through `CodeBlock`/`InlineCode` instead, so a URL
    /// inside either never reaches here at all.
    private static let bareUrlPattern = try! NSRegularExpression(
        pattern: #"https?://\S+|(?<![\w.])www\.\S+"#)

    /// GFM's "extended email autolink" grammar, likewise confirmed against `remark-gfm`'s own
    /// rendering: a local part of alphanumerics plus `+_.-`, an `@`, and a domain of at least two
    /// dot-separated labels of alphanumerics and internal hyphens. No separate trailing-punctuation
    /// pass is needed the way the URL branch needs one — the character classes below simply do not
    /// contain `.`/`,`/`!`/`)` etc. at a position that would trail the match, so GFM's domain-only
    /// exception ("a period is part of the address only when another label follows it") falls out
    /// of the grammar for free. Not chasing GFM's own further-out quirks here (a domain ending in a
    /// digit, or a `.` immediately followed by `-`/`_`, are treated inconsistently even between
    /// cmark-gfm's own reference implementation and its stated rule) — those are exactly the kind
    /// of contrived case the URL branch's own trailing-punctuation set also declines to chase.
    private static let emailPattern = try! NSRegularExpression(
        pattern:
            #"[A-Za-z0-9+_.-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+"#
    )

    /// GFM's own trimmed trailing-punctuation set — deliberately not the broader "anything that
    /// looks like sentence punctuation" a hand-rolled guess might reach for (no quotes, no square
    /// or curly brackets): matching the spec exactly is what lets iOS and the web agree on a link
    /// boundary in every case, not just the common ones.
    private static let urlTrailingPunctuation: Set<Character> = [".", ",", ":", "!", "?", "*", "_", "~"]

    /// Peels punctuation off the end of a candidate autolink one character at a time, exactly as
    /// GFM's spec describes: ordinary trailing punctuation always comes off, but a trailing `)` is
    /// removed only when the candidate has more `)` than `(` in it — a URL like Wikipedia's own
    /// `.../wiki/Foo_(bar)` keeps its closing paren, while `(see https://example.com/x)` loses the
    /// outer one it never belonged to. Re-evaluated after every removal ("recursively, incrementally
    /// moving inward" in the spec's own words), since trimming a `)` can reveal more punctuation
    /// underneath it, or reveal a `(` that changes whether the NEXT `)` in from the end still counts
    /// as unbalanced.
    private static func trimTrailingPunctuation(from range: Range<String.Index>, in text: String) -> Range<String.Index>
    {
        var range = range
        while let last = text[range].last {
            if urlTrailingPunctuation.contains(last) {
                range = range.lowerBound..<text.index(before: range.upperBound)
            } else if last == ")" {
                let opens = text[range].count { $0 == "(" }
                let closes = text[range].count { $0 == ")" }
                guard closes > opens else { break }
                range = range.lowerBound..<text.index(before: range.upperBound)
            } else {
                break
            }
        }
        return range
    }

    private enum AutolinkKind {
        case url
        case email
    }

    private static func autolinkedRuns(in text: String, style: InlineStyle) -> [InlineRun] {
        let fullRange = NSRange(text.startIndex..., in: text)
        var candidates: [(range: Range<String.Index>, kind: AutolinkKind)] = []
        for match in bareUrlPattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            candidates.append((range, .url))
        }
        for match in emailPattern.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { continue }
            // A URL already covering this span wins — the "user@example.com" inside
            // "https://user@example.com" is not a second, nested autolink.
            guard !candidates.contains(where: { $0.range.overlaps(range) }) else { continue }
            candidates.append((range, .email))
        }
        guard !candidates.isEmpty else { return [InlineRun(text: text, style: style)] }
        candidates.sort { $0.range.lowerBound < $1.range.lowerBound }

        var runs: [InlineRun] = []
        var cursor = text.startIndex
        for candidate in candidates {
            let matchRange = candidate.range
            if cursor < matchRange.lowerBound {
                runs.append(InlineRun(text: String(text[cursor..<matchRange.lowerBound]), style: style))
            }

            switch candidate.kind {
            case .email:
                let visible = String(text[matchRange])
                runs.append(InlineRun(text: visible, style: style, destination: "mailto:" + visible))

            case .url:
                let urlRange = trimTrailingPunctuation(from: matchRange, in: text)

                if urlRange.isEmpty {
                    // Trimmed away entirely — every character was punctuation, so there was never
                    // a real URL here (a bare "https://" with nothing after it, say). Shown as
                    // plain text rather than as a link to nowhere.
                    runs.append(InlineRun(text: String(text[matchRange]), style: style))
                } else {
                    let visible = String(text[urlRange])
                    let destination =
                        visible.hasPrefix("http://") || visible.hasPrefix("https://")
                        ? visible : "http://" + visible
                    runs.append(InlineRun(text: visible, style: style, destination: destination))
                    if urlRange.upperBound < matchRange.upperBound {
                        runs.append(
                            InlineRun(text: String(text[urlRange.upperBound..<matchRange.upperBound]), style: style))
                    }
                }
            }
            cursor = matchRange.upperBound
        }
        if cursor < text.endIndex {
            runs.append(InlineRun(text: String(text[cursor...]), style: style))
        }
        return runs
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
