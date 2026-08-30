import Foundation

/// The fixed chrome around a card's measured content — header, padding, inter-card and inter-row
/// spacing — kept as named constants in one place so a height computed here and a view laying
/// itself out in `PAI/` can never quietly disagree about what a pixel of "chrome" is for.
///
/// Every constant is named for the exact SwiftUI modifier it stands in for (`cardHorizontalPadding`
/// is `CardChrome`'s own `.padding(.horizontal, cardHorizontalPadding)`, not a derived total), so a
/// reader can grep one number in `TranscriptCards.swift` and land on the one place its meaning is
/// spelled out. A horizontal one is a single edge's padding, to be doubled by whichever side needs
/// the total; a vertical one is already whatever it names.
public enum TranscriptRowMetrics {
    /// A collapsible card's header row: chevron, icon, label, optional status dot.
    public static let cardHeaderHeight: Double = 32
    /// Space between a card's header and its content, and between its content and the card's
    /// bottom edge — applied once total, not per edge, since nothing here needs the two halves
    /// distinguished.
    public static let cardContentVerticalPadding: Double = 12
    /// Space between stacked cards within one assistant turn (the web's `space-y-2`).
    public static let interCardSpacing: Double = 8
    /// A bubble's own padding — a user, assistant, relayed or command-with-args bubble has no
    /// header/chevron, just padding around its text.
    public static let bubbleVerticalPadding: Double = 10
    /// One attachment chip under a user bubble.
    public static let attachmentChipHeight: Double = 22
    /// The row's trailing timestamp line.
    public static let timestampHeight: Double = 16

    // MARK: - Horizontal insets

    /// `CardChrome`'s own `.padding(.horizontal, cardHorizontalPadding)`, applied to a
    /// collapsible card's header and content alike.
    public static let cardHorizontalPadding: Double = 10
    /// Every bubble-shaped card's own `.padding(.horizontal, bubbleHorizontalPadding)` — a user,
    /// assistant, relayed or command-with-args bubble.
    public static let bubbleHorizontalPadding: Double = 14
    /// `ToolBodyText`'s and `MarkdownContentView`'s shared `.padding(codeBlockPadding)` around a
    /// rendered code block's text, applied on every edge — it both narrows the text TextKit wraps
    /// at and adds to the block's own height, since the padding is inside the box the block draws.
    public static let codeBlockPadding: Double = 8
    /// A blockquote's rule bar, in `MarkdownContentView`'s `Rectangle().frame(width:
    /// blockQuoteRuleWidth)`.
    public static let blockQuoteRuleWidth: Double = 3
    /// The gap between a blockquote's rule and its text, in `MarkdownContentView`'s
    /// `HStack(spacing: blockQuoteSpacing)`.
    public static let blockQuoteSpacing: Double = 8
    /// The gap between a list item's marker and its content, in `MarkdownContentView`'s
    /// `HStack(alignment: .top, spacing: listMarkerSpacing)`.
    public static let listMarkerSpacing: Double = 6
    /// The gap between stacked list items, in `MarkdownContentView`'s `VStack(alignment: .leading,
    /// spacing: listItemSpacing)`.
    public static let listItemSpacing: Double = 4
    /// A generous stand-in for a list marker's own intrinsic width — a bullet is narrower than
    /// this, an ordered marker past two digits is wider. Deliberately erring wide: reserving more
    /// than a marker needs wraps the measured text a line earlier than the view does (a blank gap,
    /// the safe direction per the `scrolling` skill), where reserving too little would clip.
    public static let listMarkerReservedWidth: Double = 24
    /// A relayed bubble's "sender · group" line and a command bubble's own-name line — both drawn
    /// above the body text and pinned to this height via an explicit `.frame(height:)` in the
    /// view, so the two can never drift the way an unconstrained font's intrinsic size could.
    public static let bubbleLabelLineHeight: Double = 16
    /// The gap below a bubble's label line, in the enclosing `VStack(spacing: bubbleLabelSpacing)`.
    public static let bubbleLabelSpacing: Double = 4
    /// A `Divider()`'s rendered thickness — a hairline, not a measured line of text.
    public static let thematicBreakHeight: Double = 1
    /// `GfmTableView`'s own `Grid(verticalSpacing: tableRowSpacing)`, between every pair of
    /// adjacent rows including the divider row.
    public static let tableRowSpacing: Double = 6
    /// The `Divider()` `GfmTableView` draws between its header and its first data row.
    public static let tableDividerHeight: Double = 1
}

/// The exact height one transcript row (one `Message`) occupies — nothing here is ever an
/// estimate a view corrects once it is on screen; see the `scrolling` skill's central rule.
///
/// Deliberately ignorant of ``MarkdownTableLayout``: a `.table` block's height is the real
/// measurer's problem (``BlockMeasuring/height(of:width:environment:)``'s doc comment says so
/// explicitly), so this calls ``MessageContentLayoutComposer`` exactly the way any other block
/// list would, and never special-cases a block kind itself. That keeps this type testable against
/// the same stub every other composition test already uses, with nothing about tables to fake.
public enum TranscriptRowLayout {

    /// `nil` for a message whose ``TranscriptRowPlan/cards(for:isExpanded:)`` is empty — a route
    /// that renders nothing at all. A caller filters those out of the row list; this never hands
    /// back a height of `0` for a row that is still supposed to occupy a cell.
    public static func height(
        for message: Message,
        width: Double,
        environment: MeasurementEnvironment,
        isExpanded: (String) -> Bool,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache,
        metrics: MessageLayoutMetrics
    ) -> Double? {
        let cards = TranscriptRowPlan.cards(for: message, isExpanded: isExpanded)
        guard !cards.isEmpty else { return nil }

        var total: Double = 0
        for (index, card) in cards.enumerated() {
            if index > 0 { total += TranscriptRowMetrics.interCardSpacing }
            total += height(
                of: card, width: width, environment: environment, measurer: measurer, cache: cache, metrics: metrics)
        }
        if message.timestamp != nil {
            // `TranscriptRowContent`'s own `VStack` puts this same spacing before every child,
            // the timestamp `Text` included — never omitted, since `cards` is never empty here.
            total += TranscriptRowMetrics.interCardSpacing + TranscriptRowMetrics.timestampHeight
        }
        return total
    }

    /// The width `card`'s own text wraps at — the cell width minus whichever horizontal padding
    /// `TranscriptCardKindView` draws that kind inside, so a wrap this measures and a wrap the
    /// view lays out can never be computed from two different widths.
    private static func contentWidth(for kind: TranscriptCardPlan.Kind, cellWidth: Double) -> Double {
        switch kind {
        case .userBubble, .relayedBubble, .assistantBubble, .command:
            return max(0, cellWidth - 2 * TranscriptRowMetrics.bubbleHorizontalPadding)
        case .thinking, .toolCall, .toolResult, .agentMessage, .system, .legacyCommandOutput:
            return max(0, cellWidth - 2 * TranscriptRowMetrics.cardHorizontalPadding)
        }
    }

    private static func height(
        of card: TranscriptCardPlan,
        width: Double,
        environment: MeasurementEnvironment,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache,
        metrics: MessageLayoutMetrics
    ) -> Double {
        let content = MessageContentLayoutComposer.layout(
            of: card.blocks, width: contentWidth(for: card.kind, cellWidth: width), environment: environment,
            metrics: metrics, measurer: measurer, cache: cache
        ).totalHeight
        // The line a relayed bubble's sender or a command's own name draws above its body text —
        // pinned to the same `.frame(height:)` the view gives that line, see
        // ``TranscriptRowMetrics/bubbleLabelLineHeight``'s doc comment.
        let labelChrome = TranscriptRowMetrics.bubbleLabelLineHeight + TranscriptRowMetrics.bubbleLabelSpacing

        switch card.kind {
        case .userBubble(let text, let attachmentPaths):
            let textHeight = text.isEmpty ? 0 : content
            let chips = Double(attachmentPaths.count) * TranscriptRowMetrics.attachmentChipHeight
            return textHeight + chips + TranscriptRowMetrics.bubbleVerticalPadding

        case .relayedBubble(let text, _, _):
            return (text.isEmpty ? 0 : content) + labelChrome + TranscriptRowMetrics.bubbleVerticalPadding

        case .assistantBubble:
            return content + TranscriptRowMetrics.bubbleVerticalPadding

        case .command(_, let args):
            // No arguments degrades to a compact, non-interactive line with no header chrome at
            // all — matching the web's "an action with nothing to show".
            guard args != nil else { return TranscriptRowMetrics.cardHeaderHeight }
            return content + labelChrome + TranscriptRowMetrics.bubbleVerticalPadding

        case .thinking, .toolCall, .toolResult, .agentMessage, .system, .legacyCommandOutput:
            let hasContent = !card.blocks.isEmpty
            return TranscriptRowMetrics.cardHeaderHeight
                + (hasContent ? content + TranscriptRowMetrics.cardContentVerticalPadding : 0)
        }
    }
}
