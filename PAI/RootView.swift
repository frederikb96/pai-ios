import PAIKit
import SwiftUI

/// The app's first screen: a smoke test made visible.
///
/// It renders a fixed markdown sample through the real ``MarkdownParser``, so a screenshot of it
/// is evidence that the package linked, that parsing runs on a device, and that the block kinds
/// reach the screen. It is deliberately not the transcript UI — that arrives with the
/// `UICollectionView` layer and its precomputed heights.
struct RootView: View {
    private let blocks = MarkdownParser.parse(Self.sample)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                        BlockView(block: block)
                            .accessibilityIdentifier("block-\(index)")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("PAI")
            .accessibilityIdentifier("root-scroll")
        }
    }

    /// Covers one of every block kind, so a missing case is visible rather than merely untested.
    private static let sample = """
        # PAI

        Renders through `MarkdownParser`, so this screen is **evidence** the package linked.

        - a list item
        - [x] a finished one

        | block | status |
        | --- | --- |
        | table | rendered |

        ```swift
        let blocks = MarkdownParser.parse(source)
        ```

        > Heights are precomputed, never self-sized.
        """
}

/// A deliberately plain renderer. Its job is to prove every block kind survives to the screen,
/// not to look like the finished app.
private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(text.plainText)
                .font(level <= 1 ? .largeTitle : .title2)
                .bold()
        case .paragraph(let text):
            Text(attributed(text))
        case .codeBlock(_, let code):
            Text(code)
                .font(.system(.footnote, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        case .blockQuote(let inner):
            HStack(spacing: 8) {
                Rectangle().frame(width: 3).foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(inner.enumerated()), id: \.offset) { _, child in
                        BlockView(block: child)
                    }
                }
            }
        case .list(let list):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text(marker(for: list.marker, at: index, checkbox: item.checkbox))
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(item.blocks.enumerated()), id: \.offset) { _, child in
                                BlockView(block: child)
                            }
                        }
                    }
                }
            }
        case .table(let table):
            VStack(alignment: .leading, spacing: 4) {
                row(table.header, bold: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    row(cells, bold: false)
                }
            }
        case .thematicBreak:
            Divider()
        case .htmlBlock(let raw):
            Text(raw).font(.system(.footnote, design: .monospaced)).foregroundStyle(.secondary)
        }
    }

    /// Applies the styling an `InlineText`'s runs carry.
    ///
    /// Built as one `AttributedString` rather than by concatenating `Text` values: `Text + Text`
    /// is deprecated from iOS 26, and an attributed string is what the measuring renderer will
    /// need anyway, since a height can be computed from one without a view existing.
    private func attributed(_ text: InlineText) -> AttributedString {
        var result = AttributedString()
        for run in text.runs {
            var piece = AttributedString(run.text)
            var font: Font = run.style.contains(.code) ? .system(.body, design: .monospaced) : .body
            if run.style.contains(.bold) { font = font.bold() }
            if run.style.contains(.italic) { font = font.italic() }
            piece.font = font
            if run.style.contains(.strikethrough) { piece.strikethroughStyle = .single }
            if let destination = run.destination, let url = URL(string: destination) {
                piece.link = url
            }
            result.append(piece)
        }
        return result
    }

    private func marker(for kind: MarkdownList.Marker, at index: Int, checkbox: MarkdownListItem.Checkbox?)
        -> String
    {
        if let checkbox { return checkbox == .checked ? "☑" : "☐" }
        switch kind {
        case .bullet: return "•"
        case .ordered(let start): return "\(Int(start) + index)."
        }
    }

    private func row(_ cells: [InlineText], bold: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(cell.plainText)
                    .bold(bold)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
