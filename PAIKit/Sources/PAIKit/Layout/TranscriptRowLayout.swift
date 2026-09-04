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
    /// The gap between a user bubble's own text and its first attachment chip, and between
    /// chips themselves — `UserBubbleView`'s own `VStack(spacing: attachmentChipSpacing)`.
    public static let attachmentChipSpacing: Double = 6
    /// The gap between sibling blocks in one markdown content stack — `MarkdownContentView`'s
    /// own `VStack(spacing: markdownBlockSpacing)`, which draws a card's own top-level blocks and
    /// a list item's or block quote's nested ones identically. `TranscriptCards.swift`'s
    /// `TranscriptContentMetrics.blockSpacing` re-exports this exact value rather than declaring
    /// its own, since a package in `PAIKit/Layout/` cannot see the app target that actually draws
    /// it, and ``NestedBlockLayout`` needs this same number.
    public static let markdownBlockSpacing: Double = 8
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
    /// A fixed reserved gap on the leading edge of every right-aligned bubble (Freddy's own
    /// message, a relayed one, a command with arguments, an assistant reply) — what stops a long
    /// message going edge-to-edge and gives the eye a gutter to read which side it is addressed
    /// from, serving the same purpose as the web's `max-w-[80%]` without copying its percentage.
    /// Applied on the side a bubble is *not* addressed from, so the same number is a leading
    /// padding on a right-aligned bubble and a trailing one on the assistant's. A fixed point
    /// value rather than a fraction of the row's own width, so the view (a `.padding`) and the
    /// measurer (a width subtraction) compute it from the exact same number rather than two
    /// formulas that could drift apart.
    public static let bubbleGutter: Double = 48
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

    /// The vertical distance from the top of `message`'s row to the top of one block inside one
    /// of its cards — the same origin and units ``height(for:width:environment:isExpanded:measurer:cache:metrics:)``'s
    /// own total is in.
    ///
    /// Exists because landing a search hit on screen cannot stop at "scroll to this row": a real
    /// row can run to thousands of points (one agent report in a real transcript measures
    /// 12382px), and scrolling only to its top would not bring a hit deep inside it into view.
    /// This gives the exact point within the row without needing character-level access to the
    /// text a cell draws — the block it is in is already known and already measured.
    ///
    /// `nil` when `cardIndex` is out of range for `message`'s current plan; `blockIndex` out of
    /// range (the card is not expanded yet, so its `blocks` is empty) degrades to the top of the
    /// card's own content rather than failing — a caller expands the card before asking this, but
    /// a stale index should land somewhere reasonable rather than crash.
    public static func blockOffset(
        cardIndex: Int,
        blockIndex: Int,
        for message: Message,
        width: Double,
        environment: MeasurementEnvironment,
        isExpanded: (String) -> Bool,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache,
        metrics: MessageLayoutMetrics
    ) -> Double? {
        let cards = TranscriptRowPlan.cards(for: message, isExpanded: isExpanded)
        guard cards.indices.contains(cardIndex) else { return nil }

        var total: Double = 0
        for index in 0..<cardIndex {
            if index > 0 { total += TranscriptRowMetrics.interCardSpacing }
            total += height(
                of: cards[index], width: width, environment: environment, measurer: measurer, cache: cache,
                metrics: metrics)
        }
        if cardIndex > 0 { total += TranscriptRowMetrics.interCardSpacing }

        let card = cards[cardIndex]
        total += chromeBeforeContent(of: card.kind)
        guard card.blocks.indices.contains(blockIndex) else { return total }

        let content = MessageContentLayoutComposer.layout(
            of: card.blocks, width: contentWidth(for: card.kind, cellWidth: width), environment: environment,
            metrics: metrics, measurer: measurer, cache: cache)
        total += content.blocks[blockIndex].offset
        return total
    }

    /// Distance from a card's own top edge to the top of its measured content — the counterpart
    /// to what ``height(of:width:environment:measurer:cache:metrics:)`` adds *after* the content
    /// for that same kind, kept as its own function so the two can never quietly drift onto
    /// different numbers for the same chrome. Derived from the same view structure that function's
    /// own doc comment reasons about, not measured independently.
    private static func chromeBeforeContent(of kind: TranscriptCardPlan.Kind) -> Double {
        switch kind {
        case .userBubble:
            return TranscriptRowMetrics.bubbleVerticalPadding / 2
        case .assistantBubble:
            return TranscriptRowMetrics.bubbleVerticalPadding / 2
        case .relayedBubble, .command, .resentUserBubble:
            let labelChrome = TranscriptRowMetrics.bubbleLabelLineHeight + TranscriptRowMetrics.bubbleLabelSpacing
            return labelChrome + TranscriptRowMetrics.bubbleVerticalPadding / 2
        case .thinking, .toolCall, .toolResult, .notifyReply, .agentMessage, .system, .legacyCommandOutput:
            return TranscriptRowMetrics.cardHeaderHeight + TranscriptRowMetrics.cardContentVerticalPadding / 2
        }
    }

    /// The width `card`'s own text wraps at — the cell width minus whichever horizontal padding
    /// `TranscriptCardKindView` draws that kind inside, so a wrap this measures and a wrap the
    /// view lays out can never be computed from two different widths.
    private static func contentWidth(for kind: TranscriptCardPlan.Kind, cellWidth: Double) -> Double {
        switch kind {
        case .userBubble, .relayedBubble, .command, .assistantBubble, .resentUserBubble:
            return max(
                0, cellWidth - TranscriptRowMetrics.bubbleGutter - 2 * TranscriptRowMetrics.bubbleHorizontalPadding)
        case .thinking, .toolCall, .toolResult, .notifyReply, .agentMessage, .system, .legacyCommandOutput:
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
            // `UserBubbleView`'s `VStack` puts its own text bubble first, one chip per
            // attachment after it — the text bubble's padding only exists when the text bubble
            // itself is drawn, and the inter-child spacing applies `childCount - 1` times
            // regardless of which children are text or chips.
            let hasText = !text.isEmpty
            let textHeight = hasText ? content + TranscriptRowMetrics.bubbleVerticalPadding : 0
            let chips = Double(attachmentPaths.count) * TranscriptRowMetrics.attachmentChipHeight
            let childCount = (hasText ? 1 : 0) + attachmentPaths.count
            let gaps =
                childCount > 1 ? Double(childCount - 1) * TranscriptRowMetrics.attachmentChipSpacing : 0
            return textHeight + chips + gaps

        case .relayedBubble(let text, _, _):
            return (text.isEmpty ? 0 : content) + labelChrome + TranscriptRowMetrics.bubbleVerticalPadding

        case .resentUserBubble(let text, let attachmentPaths):
            // Mirrors `.userBubble` exactly, not `.relayedBubble`: the label+bubble only exist
            // when there's text to caption (the web's own `{text && (…)}`), so an attachment-only
            // resend draws exactly like a plain attachment-only send — no bubble, no label.
            let hasText = !text.isEmpty
            let bubbleHeight = hasText ? content + labelChrome + TranscriptRowMetrics.bubbleVerticalPadding : 0
            let chips = Double(attachmentPaths.count) * TranscriptRowMetrics.attachmentChipHeight
            let childCount = (hasText ? 1 : 0) + attachmentPaths.count
            let gaps = childCount > 1 ? Double(childCount - 1) * TranscriptRowMetrics.attachmentChipSpacing : 0
            return bubbleHeight + chips + gaps

        case .assistantBubble(let text, let filePaths):
            // Mirrors `.userBubble` just above: the markdown bubble first (which still measures
            // the `pai-file:` marker line as ordinary text, since the message is never rewritten
            // for this), one fixed-height chip per marker after it.
            let hasText = !text.isEmpty
            let textHeight = hasText ? content + TranscriptRowMetrics.bubbleVerticalPadding : 0
            let chips = Double(filePaths.count) * TranscriptRowMetrics.attachmentChipHeight
            let childCount = (hasText ? 1 : 0) + filePaths.count
            let gaps =
                childCount > 1 ? Double(childCount - 1) * TranscriptRowMetrics.attachmentChipSpacing : 0
            return textHeight + chips + gaps

        case .command(_, let args):
            // No arguments degrades to a compact, non-interactive line with no header chrome at
            // all — matching the web's "an action with nothing to show".
            guard args != nil else { return TranscriptRowMetrics.cardHeaderHeight }
            return content + labelChrome + TranscriptRowMetrics.bubbleVerticalPadding

        case .thinking, .toolCall, .toolResult, .notifyReply, .agentMessage, .system, .legacyCommandOutput:
            // `CardChrome` pads whatever `content()` it was handed whenever it is expanded —
            // even when that content is an empty `ToolBodyText` and draws nothing, the padding
            // around it is still there. `card.blocks.isEmpty` cannot stand in for "collapsed":
            // it is also true for an *expanded* card whose body happens to be empty (a hook with
            // nothing to report, a tool result with no text), which still gets the padding.
            return TranscriptRowMetrics.cardHeaderHeight
                + (card.isExpanded ? content + TranscriptRowMetrics.cardContentVerticalPadding : 0)
        }
    }
}
