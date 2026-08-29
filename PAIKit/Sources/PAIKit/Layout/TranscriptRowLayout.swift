import Foundation

/// The fixed chrome around a card's measured content — header, padding, inter-card and inter-row
/// spacing — kept as named constants in one place so a height computed here and a view laying
/// itself out in `PAI/` can never quietly disagree about what a pixel of "chrome" is for.
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
            total += TranscriptRowMetrics.timestampHeight
        }
        return total
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
            of: card.blocks, width: width, environment: environment, metrics: metrics, measurer: measurer, cache: cache
        ).totalHeight

        switch card.kind {
        case .userBubble(let text, let attachmentPaths):
            let textHeight = text.isEmpty ? 0 : content
            let chips = Double(attachmentPaths.count) * TranscriptRowMetrics.attachmentChipHeight
            return textHeight + chips + TranscriptRowMetrics.bubbleVerticalPadding

        case .relayedBubble(let text, _, _):
            return (text.isEmpty ? 0 : content) + TranscriptRowMetrics.bubbleVerticalPadding

        case .assistantBubble:
            return content + TranscriptRowMetrics.bubbleVerticalPadding

        case .command(_, let args):
            // No arguments degrades to a compact, non-interactive line with no header chrome at
            // all — matching the web's "an action with nothing to show".
            guard args != nil else { return TranscriptRowMetrics.cardHeaderHeight }
            return content + TranscriptRowMetrics.bubbleVerticalPadding

        case .thinking, .toolCall, .toolResult, .agentMessage, .system, .legacyCommandOutput:
            let hasContent = !card.blocks.isEmpty
            return TranscriptRowMetrics.cardHeaderHeight
                + (hasContent ? content + TranscriptRowMetrics.cardContentVerticalPadding : 0)
        }
    }
}
