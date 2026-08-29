import PAIKit
import SwiftUI

/// Design-token decisions this file owns, per row 25's own note that `MessageLayoutMetrics`'s
/// spacing value "belongs with the card chrome", not with the measurement machinery in `PAIKit`.
/// Referenced from both here (the rendered spacing) and `TranscriptCollectionViewController` (the
/// measured spacing) so the two can never silently disagree about what a block of space is.
enum TranscriptContentMetrics {
    static let blockSpacing: Double = 8
}

/// One message's whole row: every card `TranscriptRowPlan` produced for it, in order, then a
/// trailing timestamp — the exact same decomposition `TranscriptRowLayout` measured, so a row
/// never renders taller or shorter than the height its cell was given.
struct TranscriptRowContent: View {
    let message: Message
    let isExpanded: (String) -> Bool
    let onToggleExpand: (String) -> Void

    private var cards: [TranscriptCardPlan] {
        TranscriptRowPlan.cards(for: message, isExpanded: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptRowMetrics.interCardSpacing) {
            ForEach(Array(cards.enumerated()), id: \.offset) { _, card in
                TranscriptCardKindView(
                    card: card,
                    isExpanded: card.expandKey.map(isExpanded) ?? true,
                    onToggle: card.expandKey.map { key in { onToggleExpand(key) } }
                )
            }
            if message.timestamp != nil {
                Text(formattedTimestamp)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                    .frame(height: TranscriptRowMetrics.timestampHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var formattedTimestamp: String {
        guard let raw = message.timestamp, let date = ISO8601DateFormatter().date(from: raw) else { return "" }
        return Self.timeFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Routes one card to its specific presentation. Every collapsible kind shares ``CardChrome``;
/// every bubble-shaped kind (a plain message, a relayed one, a command with its arguments) draws
/// itself with no chevron at all, matching the web.
struct TranscriptCardKindView: View {
    let card: TranscriptCardPlan
    let isExpanded: Bool
    let onToggle: (() -> Void)?

    var body: some View {
        switch card.kind {
        case .thinking:
            CardChrome(icon: "brain", label: "Thinking", isExpanded: isExpanded, onToggle: onToggle) {
                ToolBodyText(blocks: card.blocks)
            }

        case .toolCall(let call):
            CardChrome(
                icon: TranscriptCardKindView.toolIcon(call.name),
                label: MessageDisplay.toolCardLabel(call: call, result: nil),
                isExpanded: isExpanded, onToggle: onToggle
            ) {
                ToolBodyText(blocks: card.blocks, colorHint: TranscriptCardKindView.colorHint(forToolName: call.name))
            }

        case .toolResult(let result):
            CardChrome(
                icon: TranscriptCardKindView.toolIcon(result.toolName),
                label: MessageDisplay.toolCardLabel(call: nil, result: result), isExpanded: isExpanded,
                statusColor: result.isError ? PaiPalette.red500 : PaiPalette.green500, onToggle: onToggle
            ) {
                // A result is plain, unlike its call — only a bash *command* line or an edit's
                // diff prefixes are recoloured; a result's own output has neither.
                ToolBodyText(blocks: card.blocks)
            }

        case .userBubble(let text, let attachmentPaths):
            UserBubbleView(text: text, attachmentPaths: attachmentPaths)

        case .relayedBubble(let text, let sender, let group):
            RelayedBubbleView(text: text, sender: sender, group: group)

        case .assistantBubble:
            AssistantBubbleView(blocks: card.blocks)

        case .agentMessage(let sender, _):
            CardChrome(icon: "bubble.left.and.bubble.right", label: sender, isExpanded: isExpanded, onToggle: onToggle)
            {
                MarkdownContentView(blocks: card.blocks)
            }

        case .command(let name, let args):
            CommandCardView(name: name, args: args)

        case .system(let subtype, let content, _):
            CardChrome(
                icon: TranscriptCardKindView.systemIcon(subtype),
                label: MessageDisplay.systemLabel(subtype: subtype, content: content), isExpanded: isExpanded,
                onToggle: onToggle
            ) {
                ToolBodyText(blocks: card.blocks)
            }

        case .legacyCommandOutput:
            CardChrome(icon: "terminal", label: "Command Output", isExpanded: isExpanded, onToggle: onToggle) {
                ToolBodyText(blocks: card.blocks)
            }
        }
    }

    /// Mirrors the web's `toolIcon` — bash/read/edit/grep/glob/agent/web/skill/mcp, default
    /// terminal. Kept as SF Symbol names rather than the web's icon components.
    fileprivate static func toolIcon(_ name: String) -> String {
        let lower = name.lowercased()
        if lower == "bash" { return "terminal" }
        if lower == "read" { return "doc.text" }
        if lower.contains("edit") || lower == "write" || lower == "multiedit" { return "pencil" }
        if lower == "grep" { return "magnifyingglass" }
        if lower == "glob" { return "folder" }
        if lower.contains("agent") || lower == "task" { return "cpu" }
        if lower == "websearch" || lower == "webfetch" { return "globe" }
        if lower == "skill" { return "bolt" }
        if lower.hasPrefix("mcp__") { return "puzzlepiece" }
        return "terminal"
    }

    fileprivate static func systemIcon(_ subtype: String?) -> String {
        switch subtype {
        case "skill": return "bolt"
        case "context": return "info.circle"
        case "command", "command_output": return "terminal"
        case "image": return "photo"
        case "compact", "compact_summary": return "quote.opening"
        case "hook": return "bolt"
        case "duration": return "info.circle"
        case "interrupt": return "stop.circle"
        case "notification": return "bell"
        case "scheduled": return "clock"
        case "pai_message": return "info.circle"
        default: return "info.circle"
        }
    }

    /// A bash command's `$ ` line and an edit's `- `/`+ ` diff lines are the two places the web
    /// colours a tool body by content rather than by syntax highlighting — neither changes the
    /// text, so neither can change a measured height.
    fileprivate static func colorHint(forToolName name: String) -> ToolBodyColorHint? {
        let lower = name.lowercased()
        if lower == "bash" { return .bashCommand }
        if lower.contains("edit") { return .diff }
        return nil
    }
}

/// The collapsible-card chrome shared by tool calls/results, thinking, system lines, agent
/// messages and legacy command output — chevron, icon, label, an optional status dot, and the
/// content only while expanded.
///
/// Every constant here is ``TranscriptRowMetrics``, not a local number: this view's own height
/// and the height ``TranscriptRowLayout`` computed for the row it sits in must never drift apart,
/// and the surest way to guarantee that is to have exactly one definition of each of them.
struct CardChrome<Content: View>: View {
    let icon: String
    let label: String
    let isExpanded: Bool
    var statusColor: Color?
    let onToggle: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                onToggle?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                    Image(systemName: icon)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    Text(label)
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    if let statusColor {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                    }
                }
                .frame(height: TranscriptRowMetrics.cardHeaderHeight)
            }
            .buttonStyle(.plain)
            .disabled(onToggle == nil)

            if isExpanded {
                content()
                    .padding(.top, TranscriptRowMetrics.cardContentVerticalPadding / 2)
                    .padding(.bottom, TranscriptRowMetrics.cardContentVerticalPadding / 2)
            }
        }
        .padding(.horizontal, 10)
        .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// A card body wrapped as a single `.codeBlock` (see `TranscriptRowPlan`'s doc comment on why) —
/// rendered monospaced on a dark ground, matching the web's `<pre>`. `colorHint` recolours whole
/// lines by their literal prefix (`$ `, `- `, `+ `) without touching the text itself, so a
/// measured height built from the same string is never invalidated by how it is painted.
struct ToolBodyText: View {
    let blocks: [MarkdownBlock]
    var colorHint: ToolBodyColorHint?

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            if case .codeBlock(_, let code) = block {
                coloredText(for: code)
                    .font(PaiTypography.markdownCodeBlock.font)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PaiPalette.surface900, in: RoundedRectangle(cornerRadius: 6))
            } else {
                MarkdownContentView(blocks: [block])
            }
        }
    }

    private func coloredText(for code: String) -> Text {
        guard let colorHint else {
            return Text(code).foregroundStyle(PaiPalette.Semantic.textPrimary)
        }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        var result = Text("")
        for (index, line) in lines.enumerated() {
            let piece = Text(String(line)).foregroundStyle(colorHint.color(forLine: String(line)))
            result = index == 0 ? piece : result + Text("\n") + piece
        }
        return result
    }
}

enum ToolBodyColorHint {
    case bashCommand
    case diff

    func color(forLine line: String) -> Color {
        switch self {
        case .bashCommand:
            return line.hasPrefix("$ ") ? PaiPalette.green500 : PaiPalette.Semantic.textPrimary
        case .diff:
            if line.hasPrefix("- ") { return PaiPalette.red500 }
            if line.hasPrefix("+ ") { return PaiPalette.green500 }
            return PaiPalette.Semantic.textPrimary
        }
    }
}

/// A plain prompt Freddy (or a device on his behalf) typed — right-aligned, filled, plain text.
struct UserBubbleView: View {
    let text: String
    let attachmentPaths: [String]

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if !text.isEmpty {
                Text(text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
                    .background(PaiPalette.primary500, in: RoundedRectangle(cornerRadius: 16))
            }
            ForEach(attachmentPaths, id: \.self) { path in
                Label((path as NSString).lastPathComponent, systemImage: "paperclip")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(height: TranscriptRowMetrics.attachmentChipHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A genuine prompt relayed from another session — drawn like Freddy's own bubble but a different
/// colour, so a reader can tell it was not him. `PaiPalette` has no dedicated "relay" swatch (the
/// web's is a literal, untokenised hex outside the 21 tracked custom properties), so this uses the
/// closest named green rather than inventing a new asset-catalog colour set outside this block's
/// directory scope.
struct RelayedBubbleView: View {
    let text: String
    let sender: String
    let group: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(group.map { "\(sender) · \($0)" } ?? sender)
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(.white.opacity(0.85))
            if !text.isEmpty {
                Text(text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
        .background(PaiPalette.green600, in: RoundedRectangle(cornerRadius: 16))
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// An assistant's own reply — left-aligned, rendered as real markdown (unlike every other card,
/// which shows plain or lightly-coloured monospace).
struct AssistantBubbleView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        MarkdownContentView(blocks: blocks)
            .padding(.horizontal, 14)
            .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slash command Freddy typed. With arguments, they render unconditionally in his own bubble —
/// a reader must never click to see their own words. With none, a compact, non-interactive line.
struct CommandCardView: View {
    let name: String
    let args: String?

    var body: some View {
        if let args {
            VStack(alignment: .trailing, spacing: 4) {
                Text(name)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(.white.opacity(0.85))
                Text(args)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
            .background(PaiPalette.primary500, in: RoundedRectangle(cornerRadius: 16))
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                Text(name)
            }
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .frame(height: TranscriptRowMetrics.cardHeaderHeight, alignment: .leading)
        }
    }
}

/// Renders parsed markdown blocks. Recurses for `.blockQuote`/`.list`, whose nested blocks are
/// exactly the ones `TextKitBlockMeasurer` measures by joining with a single `"\n"` rather than
/// real paragraph spacing — see that type's doc comment for the approximation this inherits.
struct MarkdownContentView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptContentMetrics.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            styledText(text, style: .markdownBody)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            styledText(text, style: headingStyle(level))
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(_, let code):
            Text(code)
                .font(PaiTypography.markdownCodeBlock.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PaiPalette.surface900, in: RoundedRectangle(cornerRadius: 6))

        case .blockQuote(let nested):
            HStack(spacing: 8) {
                Rectangle().fill(PaiPalette.Semantic.borderStrong).frame(width: 3)
                MarkdownContentView(blocks: nested)
            }

        case .list(let list):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(marker(for: list.marker, index: index, checkbox: item.checkbox))
                            .font(PaiTypography.markdownBody.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                        MarkdownContentView(blocks: item.blocks)
                    }
                }
            }

        case .table(let table):
            GfmTableView(table: table)

        case .thematicBreak:
            Divider()

        case .htmlBlock(let raw):
            Text(raw)
                .font(PaiTypography.markdownCodeBlock.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
    }

    private func marker(for marker: MarkdownList.Marker, index: Int, checkbox: MarkdownListItem.Checkbox?) -> String {
        if let checkbox {
            return checkbox == .checked ? "☑" : "☐"
        }
        switch marker {
        case .bullet: return "•"
        case .ordered(let start): return "\(Int(start) + index)."
        }
    }

    private func headingStyle(_ level: Int) -> PaiTypography.Style {
        switch level {
        case 1: return .markdownHeading1
        case 2: return .markdownHeading2
        case 3: return .markdownHeading3
        default: return .markdownHeading4
        }
    }

    /// Links are coloured but not yet tappable — see this block's report for why that is a
    /// deliberate scope cut rather than an oversight.
    private func styledText(_ inline: InlineText, style: PaiTypography.Style) -> Text {
        var result = Text("")
        for run in inline.runs {
            var piece = Text(run.text)
                .font(run.style.contains(.code) ? PaiTypography.markdownInlineCode.font : style.font)
            if run.style.contains(.bold) { piece = piece.bold() }
            if run.style.contains(.italic) { piece = piece.italic() }
            if run.style.contains(.strikethrough) { piece = piece.strikethrough() }
            if run.destination != nil {
                piece = piece.foregroundStyle(PaiPalette.Semantic.accentText).underline()
            }
            result = result + piece
        }
        return result
    }
}

/// A GFM table, its own horizontally-scrolling grid — matching the web, a cell never wraps, so a
/// wide table scrolls instead of being cut off with nothing to reach the rest of it.
struct GfmTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { _, cell in
                        Text(cell.plainText)
                            .font(PaiTypography.bodyEmphasized.font)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    }
                }
                Divider()
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell.plainText)
                                .font(PaiTypography.markdownBody.font)
                                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        }
                    }
                }
            }
        }
    }
}
