import Foundation
import PAIKit
import SwiftUI

/// Re-exports ``TranscriptRowMetrics/markdownBlockSpacing`` under the name both this file (the
/// rendered spacing) and `TranscriptCollectionViewController` (the measured spacing, threaded
/// through `MessageLayoutMetrics`) already call it. The value itself lives in `PAIKit` rather
/// than here now, because ``NestedBlockLayout`` needs it too, for the identical gap between a
/// list item's or block quote's own nested blocks — a design-token decision this file used to own
/// alone, until measuring it correctly required reading it from the same place twice.
enum TranscriptContentMetrics {
    static let blockSpacing = TranscriptRowMetrics.markdownBlockSpacing
}

/// One occurrence to paint inside a block's own text, in that block's UTF-16 coordinates — the
/// shape every rendering function below takes its highlights in.
typealias TranscriptHighlightSpan = (range: NSRange, isCurrent: Bool)

extension Shape where Self == UnevenRoundedRectangle {
    /// Freddy's own bubble shape — a native uneven rectangle rather than a hand-drawn tail, one
    /// corner tucked in on the edge the bubble is addressed from, matching the web's `rounded-2xl
    /// rounded-br-md`. Shared by every right-aligned bubble in this file (his own prompt, a
    /// relayed one, a command with arguments): one definition, so the three can never pick
    /// slightly different radii.
    static var ownBubbleTail: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 6, topTrailingRadius: 16)
    }
}

/// The web pairs a raw-scale colour with a specific step per appearance at every call site
/// (`bg-primary-500 dark:bg-primary-600`) rather than baking the pairing into one asset — every
/// step in ``PaiPalette``'s raw scale is a fixed swatch that never varies by appearance on its
/// own (see that file's own doc comment). This mirrors the web's pairing for a bubble's own fill,
/// the one place in this file that needs it.
private func bubbleFill(light: Color, dark: Color, colorScheme: ColorScheme) -> Color {
    colorScheme == .dark ? dark : light
}

/// One message's whole row: every card `TranscriptRowPlan` produced for it, in order, then a
/// trailing timestamp — the exact same decomposition `TranscriptRowLayout` measured, so a row
/// never renders taller or shorter than the height its cell was given.
struct TranscriptRowContent: View {
    let message: Message
    let isExpanded: (String) -> Bool
    let onToggleExpand: (String) -> Void
    /// Every search hit that belongs to this message — already filtered by the caller, which
    /// knows the message id and this view does not need to. Empty outside a search.
    var highlights: [TranscriptSearchHit] = []
    var currentHit: TranscriptSearchHit?

    private var cards: [TranscriptCardPlan] {
        TranscriptRowPlan.cards(for: message, isExpanded: isExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptRowMetrics.interCardSpacing) {
            ForEach(Array(cards.enumerated()), id: \.offset) { cardIndex, card in
                TranscriptCardKindView(
                    card: card,
                    isExpanded: card.expandKey.map(isExpanded) ?? true,
                    onToggle: card.expandKey.map { key in { onToggleExpand(key) } },
                    highlightsByBlockIndex: highlightsByBlockIndex(forCardIndex: cardIndex)
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

    /// Groups this card's own hits by which block they fall in — the shape every rendering
    /// function downstream wants, since a card's content is measured and drawn block by block.
    private func highlightsByBlockIndex(forCardIndex cardIndex: Int) -> [Int: [TranscriptHighlightSpan]] {
        guard !highlights.isEmpty else { return [:] }
        var result: [Int: [TranscriptHighlightSpan]] = [:]
        for hit in highlights where hit.cardIndex == cardIndex {
            result[hit.blockIndex, default: []].append((hit.range, hit == currentHit))
        }
        return result
    }

    private var formattedTimestamp: String {
        guard let raw = message.timestamp, let date = IsoTimestamp.date(from: raw) else { return "" }
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
    var highlightsByBlockIndex: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        switch card.kind {
        case .thinking:
            CardChrome(icon: "brain", label: "Thinking", isExpanded: isExpanded, onToggle: onToggle) {
                ToolBodyText(blocks: card.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .toolCall(let call):
            CardChrome(
                icon: TranscriptCardKindView.toolIcon(call.name),
                label: MessageDisplay.toolCardLabel(call: call, result: nil),
                isExpanded: isExpanded, onToggle: onToggle
            ) {
                ToolBodyText(
                    blocks: card.blocks, colorHint: TranscriptCardKindView.colorHint(forToolName: call.name),
                    highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .toolResult(let result):
            CardChrome(
                icon: TranscriptCardKindView.toolIcon(result.toolName),
                label: MessageDisplay.toolCardLabel(call: nil, result: result), isExpanded: isExpanded,
                statusColor: result.isError ? PaiPalette.red500 : PaiPalette.green500, onToggle: onToggle
            ) {
                // A result is plain, unlike its call — only a bash *command* line or an edit's
                // diff prefixes are recoloured; a result's own output has neither.
                ToolBodyText(blocks: card.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .userBubble(let text, let attachmentPaths):
            UserBubbleView(text: text, attachmentPaths: attachmentPaths, highlights: highlightsByBlockIndex[0] ?? [])

        case .relayedBubble(let text, let sender, let group):
            RelayedBubbleView(text: text, sender: sender, group: group, highlights: highlightsByBlockIndex[0] ?? [])

        case .assistantBubble:
            AssistantBubbleView(blocks: card.blocks, highlights: highlightsByBlockIndex)

        case .agentMessage(let sender, _):
            CardChrome(icon: "bubble.left.and.bubble.right", label: sender, isExpanded: isExpanded, onToggle: onToggle)
            {
                MarkdownContentView(blocks: card.blocks, highlights: highlightsByBlockIndex)
            }

        case .command(let name, let args):
            CommandCardView(name: name, args: args, highlights: highlightsByBlockIndex[0] ?? [])

        case .system(let subtype, let content, _):
            CardChrome(
                icon: TranscriptCardKindView.systemIcon(subtype),
                label: MessageDisplay.systemLabel(subtype: subtype, content: content), isExpanded: isExpanded,
                onToggle: onToggle
            ) {
                ToolBodyText(blocks: card.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
            }

        case .legacyCommandOutput:
            CardChrome(icon: "terminal", label: "Command Output", isExpanded: isExpanded, onToggle: onToggle) {
                ToolBodyText(blocks: card.blocks, highlightsByBlockIndex: highlightsByBlockIndex)
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

/// A shared icon scale for a card's own chrome glyphs — the chevron and the tool/system icon read
/// at the same size, matching the web's uniform 16px (`w-4 h-4`) rather than the mix of an
/// unmodified system default and a smaller caption size.
private let cardChromeIconFont = Font.system(size: 13, weight: .medium)

/// The collapsible-card chrome shared by tool calls/results, thinking, system lines, agent
/// messages and legacy command output — chevron, icon, label, an optional status dot, and the
/// content only while expanded.
///
/// Outlined rather than filled — a border on the page ground, matching the web's own
/// `border border-surface-200 dark:border-surface-700` (no background class at all). Six
/// different kinds of card filling the same solid slab is what made the transcript unreadable as
/// "which of these is the answer"; an outline on a near-black page reads as air between rows
/// instead of another wall, and it is what the reply in ``AssistantBubbleView`` is deliberately
/// contrasted against. The border is an `.overlay`, not a second background, so it changes
/// nothing about the box's own size.
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
                        .font(cardChromeIconFont)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                    Image(systemName: icon)
                        .font(cardChromeIconFont)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    Text(label)
                        .font(PaiTypography.captionEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
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
        .padding(.horizontal, TranscriptRowMetrics.cardHorizontalPadding)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(PaiPalette.Semantic.borderStrong, lineWidth: 1))
    }
}

/// A card body wrapped as a single `.codeBlock` (see `TranscriptRowPlan`'s doc comment on why) —
/// rendered monospaced on a raised ground, matching the web's `<pre>` (`bg-surface-100
/// dark:bg-surface-800`, the same pairing ``PaiPalette/Semantic/raisedSurface`` already carries —
/// a fixed `surface900` read as a black box in light mode). `colorHint` recolours whole lines by
/// their literal prefix (`$ `, `- `, `+ `) without touching the text itself, so a measured height
/// built from the same string is never invalidated by how it is painted.
struct ToolBodyText: View {
    let blocks: [MarkdownBlock]
    var colorHint: ToolBodyColorHint?
    var highlightsByBlockIndex: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            if case .codeBlock(_, let code) = block {
                coloredText(for: code, highlights: highlightsByBlockIndex[index] ?? [])
                    .textSelection(.enabled)
                    .padding(TranscriptRowMetrics.codeBlockPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 6))
            } else {
                MarkdownContentView(blocks: [block], highlights: [0: highlightsByBlockIndex[index] ?? []])
            }
        }
    }

    /// Builds the body as one `AttributedString` rather than concatenated `Text` pieces — a
    /// search highlight needs a background colour on an arbitrary sub-range, and only
    /// `Text(AttributedString)` can carry one without inserting anything into the text (see
    /// ``TranscriptSearchPainting``'s own doc comment for why that property matters). Per-line
    /// recolouring from `colorHint` sets only *foreground*, so a highlight's background paints
    /// over it without erasing which line is a command versus a diff addition or removal.
    private func coloredText(for code: String, highlights: [TranscriptHighlightSpan]) -> Text {
        var attributed = AttributedString(code)
        attributed.font = PaiTypography.markdownCodeBlock.font
        attributed.foregroundColor = PaiPalette.Semantic.textPrimary

        if let colorHint {
            var cursor = 0
            for substring in code.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(substring)
                let length = line.utf16.count
                defer { cursor += length + 1 }  // +1 for the "\n" this split consumed between lines
                guard length > 0,
                    let range = TranscriptTextHighlighting.attributedRange(
                        NSRange(location: cursor, length: length), source: code, in: attributed)
                else { continue }
                attributed[range].foregroundColor = colorHint.color(forLine: line)
            }
        }

        TranscriptTextHighlighting.apply(highlights, to: &attributed, source: code)
        return Text(attributed)
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

/// A plain prompt Freddy (or a device on his behalf) typed — right-aligned, filled, plain text,
/// tucked into ``ownBubbleTail`` with a fixed leading gutter (``TranscriptRowMetrics/bubbleLeadingGutter``)
/// so a long message stops short of the row's own left edge instead of going flush across it —
/// the gutter is what tells the eye whose message it is.
struct UserBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let attachmentPaths: [String]
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: TranscriptRowMetrics.attachmentChipSpacing) {
            if !text.isEmpty {
                TranscriptTextHighlighting.plainText(text, font: PaiTypography.body.font, highlights: highlights)
                    .foregroundStyle(.white)
                    .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
                    .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
                    .background(
                        bubbleFill(light: PaiPalette.primary500, dark: PaiPalette.primary600, colorScheme: colorScheme),
                        in: .ownBubbleTail)
            }
            ForEach(attachmentPaths, id: \.self) { path in
                Label((path as NSString).lastPathComponent, systemImage: "paperclip")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(height: TranscriptRowMetrics.attachmentChipHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, TranscriptRowMetrics.bubbleLeadingGutter)
    }
}

/// A genuine prompt relayed from another session — drawn like Freddy's own bubble but a different
/// colour (``PaiPalette/relay500``/``relay600``, mirroring `pai-cloud`'s `--color-relay-500/600`
/// exactly, not the closest named green), so a reader can tell it was not him.
struct RelayedBubbleView: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let sender: String
    let group: String?
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        VStack(alignment: .trailing, spacing: TranscriptRowMetrics.bubbleLabelSpacing) {
            Text(group.map { "\(sender) · \($0)" } ?? sender)
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(.white.opacity(0.85))
                .frame(height: TranscriptRowMetrics.bubbleLabelLineHeight, alignment: .leading)
            if !text.isEmpty {
                TranscriptTextHighlighting.plainText(text, font: PaiTypography.body.font, highlights: highlights)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
        .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
        .background(
            bubbleFill(light: PaiPalette.relay500, dark: PaiPalette.relay600, colorScheme: colorScheme),
            in: .ownBubbleTail
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, TranscriptRowMetrics.bubbleLeadingGutter)
    }
}

/// An assistant's own reply — left-aligned, rendered as real markdown (unlike every other card,
/// which shows plain or lightly-coloured monospace), and deliberately uncontained: no fill, no
/// corner radius, sitting directly on the page at reading width. Every other card in this file is
/// chrome around measured content; this is the one thing a reader came to read, so it is the one
/// card that must not look like the rest of them. `TranscriptRowLayout`'s own `assistantBubble`
/// case mirrors this exactly — no vertical padding, `cardHorizontalPadding` for the horizontal
/// inset, since there is no bubble padding left to measure.
struct AssistantBubbleView: View {
    let blocks: [MarkdownBlock]
    var highlights: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        MarkdownContentView(blocks: blocks, highlights: highlights)
            .padding(.horizontal, TranscriptRowMetrics.cardHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A slash command Freddy typed. With arguments, they render unconditionally in his own bubble —
/// a reader must never click to see their own words. With none, a compact, non-interactive line.
struct CommandCardView: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let args: String?
    var highlights: [TranscriptHighlightSpan] = []

    var body: some View {
        if let args {
            VStack(alignment: .trailing, spacing: TranscriptRowMetrics.bubbleLabelSpacing) {
                Text(name)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(height: TranscriptRowMetrics.bubbleLabelLineHeight, alignment: .leading)
                TranscriptTextHighlighting.plainText(args, font: PaiTypography.body.font, highlights: highlights)
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, TranscriptRowMetrics.bubbleHorizontalPadding)
            .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
            .background(
                bubbleFill(light: PaiPalette.primary500, dark: PaiPalette.primary600, colorScheme: colorScheme),
                in: .ownBubbleTail
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, TranscriptRowMetrics.bubbleLeadingGutter)
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

/// Renders parsed markdown blocks. Recurses for `.blockQuote`/`.list`: each nested
/// `MarkdownContentView` narrows by exactly the inset its own `HStack` (a block quote's rule, a
/// list item's marker) reserves, and `TextKitBlockMeasurer` mirrors that same narrowing through
/// `NestedBlockLayout` rather than measuring the nested content flattened at the outer width.
///
/// `highlights` is keyed by index into `blocks` — meaningful only at the top level a card's own
/// plan indexes against (see `TranscriptSearchIndex`'s doc comment). A recursive call for a
/// nested list item or blockquote passes none: a hit's `blockIndex` names a position in the
/// *card's* flat block list, which does not correspond to a position inside a block nested
/// several levels down, so a hit inside a list or a blockquote still opens and scrolls to the
/// right row but is not painted character-for-character inside it.
struct MarkdownContentView: View {
    let blocks: [MarkdownBlock]
    var highlights: [Int: [TranscriptHighlightSpan]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: TranscriptContentMetrics.blockSpacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                blockView(block, highlights: highlights[index] ?? [])
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock, highlights: [TranscriptHighlightSpan]) -> some View {
        switch block {
        case .paragraph(let text):
            styledText(text, style: PaiTypography.markdownBody, highlights: highlights)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            styledText(text, style: headingStyle(level), highlights: highlights)
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(_, let code):
            TranscriptTextHighlighting.plainText(
                code, font: PaiTypography.markdownCodeBlock.font, highlights: highlights
            )
            .foregroundStyle(PaiPalette.Semantic.textPrimary)
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 6))

        case .blockQuote(let nested):
            HStack(spacing: TranscriptRowMetrics.blockQuoteSpacing) {
                Rectangle().fill(PaiPalette.Semantic.borderStrong).frame(
                    width: TranscriptRowMetrics.blockQuoteRuleWidth)
                MarkdownContentView(blocks: nested)
            }

        case .list(let list):
            VStack(alignment: .leading, spacing: TranscriptRowMetrics.listItemSpacing) {
                ForEach(Array(list.items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: TranscriptRowMetrics.listMarkerSpacing) {
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
            TranscriptTextHighlighting.plainText(
                raw, font: PaiTypography.markdownCodeBlock.font, highlights: highlights
            )
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
        case 1: return PaiTypography.markdownHeading1
        case 2: return PaiTypography.markdownHeading2
        case 3: return PaiTypography.markdownHeading3
        default: return PaiTypography.markdownHeading4
        }
    }

    /// Links are coloured but not yet tappable — a deliberate cut, not an oversight.
    ///
    /// Built as one `AttributedString` covering the whole paragraph rather than concatenated
    /// `Text` runs — a search highlight needs a background colour over an arbitrary sub-range,
    /// which only `Text(AttributedString)` can carry without inserting anything into the text.
    /// `InlinePresentationIntent` stands in for `.bold()`/`.italic()`: it is the same mechanism
    /// `Text(AttributedString(markdown:))` itself uses to render emphasis, so it needs no font
    /// substitution and cannot disagree with what `TextKitBlockMeasurer` already measured this
    /// same run at.
    private func styledText(_ inline: InlineText, style: PaiTypography.Style, highlights: [TranscriptHighlightSpan])
        -> Text
    {
        let source = inline.plainText
        var attributed = AttributedString(source)
        attributed.font = style.font

        var cursor = 0
        for run in inline.runs {
            let length = run.text.utf16.count
            defer { cursor += length }
            guard length > 0,
                let range = TranscriptTextHighlighting.attributedRange(
                    NSRange(location: cursor, length: length), source: source, in: attributed)
            else { continue }

            if run.style.contains(.code) {
                attributed[range].font = PaiTypography.markdownInlineCode.font
            }
            var intent: InlinePresentationIntent = []
            if run.style.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.style.contains(.italic) { intent.insert(.emphasized) }
            if !intent.isEmpty { attributed[range].inlinePresentationIntent = intent }
            if run.style.contains(.strikethrough) { attributed[range].strikethroughStyle = .single }
            if run.destination != nil {
                attributed[range].foregroundColor = PaiPalette.Semantic.accentText
                attributed[range].underlineStyle = .single
            }
        }

        TranscriptTextHighlighting.apply(highlights, to: &attributed, source: source)
        return Text(attributed)
    }
}

/// A GFM table, its own horizontally-scrolling grid — matching the web, a cell never wraps, so a
/// wide table scrolls instead of being cut off with nothing to reach the rest of it.
///
/// A hit inside a cell still opens and scrolls to the row (the store-side index covers it) — it
/// is just not painted inside the cell, the one scope cut `MarkdownContentView`'s own doc comment
/// names, since a cell here is a single flat `Text` with no run-splitting machinery at all.
struct GfmTableView: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: TranscriptRowMetrics.tableRowSpacing) {
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

/// Shared plumbing for painting a search highlight over an `AttributedString` without changing
/// what it measures as — see ``TranscriptSearchPainting``'s own doc comment for the constraint
/// this exists to serve. Every rendering function above that can carry a highlight goes through
/// this, so there is exactly one place that converts a UTF-16 ``NSRange`` into an
/// `AttributedString` sub-range and exactly one place that decides what a hit looks like painted.
enum TranscriptTextHighlighting {
    /// A plain, unstyled run of text with no per-character formatting of its own — a bubble's
    /// body, a code block, raw HTML source. `font` is the one attribute this always sets; a
    /// caller applying its own colour via an outer `.foregroundStyle()` still wins wherever a
    /// highlight has not overridden it, since this leaves no foreground attribute of its own in
    /// the unhighlighted stretches.
    static func plainText(_ text: String, font: Font, highlights: [TranscriptHighlightSpan]) -> Text {
        var attributed = AttributedString(text)
        attributed.font = font
        apply(highlights, to: &attributed, source: text)
        return Text(attributed)
    }

    /// Converts a UTF-16 `NSRange` measured against `source` into the equivalent sub-range of
    /// `attributed` — valid whenever `attributed`'s characters are `source`'s characters in the
    /// same order, which every caller here guarantees by building `attributed` directly from
    /// `source` before calling this.
    static func attributedRange(_ nsRange: NSRange, source: String, in attributed: AttributedString)
        -> Range<AttributedString.Index>?
    {
        guard let range = Range(nsRange, in: source) else { return nil }
        guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
            let upper = AttributedString.Index(range.upperBound, within: attributed)
        else { return nil }
        return lower..<upper
    }

    /// Paints every highlight onto `attributed` as a background colour (and, for the current hit,
    /// a foreground colour too, for contrast against its brighter background) — never anything
    /// that could change what a width this text was already measured at wraps to.
    static func apply(_ highlights: [TranscriptHighlightSpan], to attributed: inout AttributedString, source: String) {
        guard !highlights.isEmpty else { return }
        let segments = TranscriptSearchPainting.segments(length: source.utf16.count, highlights: highlights)
        for segment in segments where segment.emphasis != .none {
            guard let range = attributedRange(segment.range, source: source, in: attributed) else { continue }
            switch segment.emphasis {
            case .none:
                break
            case .hit:
                attributed[range].backgroundColor = PaiPalette.SearchHighlight.allHits
            case .currentHit:
                attributed[range].backgroundColor = PaiPalette.SearchHighlight.currentBackground
                attributed[range].foregroundColor = PaiPalette.SearchHighlight.currentForeground
            }
        }
    }
}
