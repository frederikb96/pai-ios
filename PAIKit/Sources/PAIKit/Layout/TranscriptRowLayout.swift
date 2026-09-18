import Foundation

/// The fixed chrome around a card's measured content — the rail, the marker column, padding and
/// the trailer — kept as named constants in one place so a height computed here and a view laying
/// itself out in `PAI/` can never quietly disagree about what a point of "chrome" is for.
///
/// Every constant is named for the exact SwiftUI modifier it stands in for
/// (``activityHorizontalInset`` is `ActivityRowView`'s own leading `.padding`, not a derived
/// total), so a reader can grep one number in `TranscriptCards.swift` and land on the one place
/// its meaning is spelled out. A horizontal one is a single edge's padding, to be doubled by
/// whichever side needs the total; a vertical one is already whatever it names.
public enum TranscriptRowMetrics {

    // MARK: - The activity grid

    /// The vertical rule down the left of every activity row, which is what makes a run of them
    /// read as one stream rather than as a pile of separate cards.
    public static let railWidth: Double = 2
    /// The column holding one activity row's glyph.
    public static let markerColumnWidth: Double = 22
    /// The gap between the marker column and the body, and between the body and the time column.
    public static let gridGap: Double = 6
    /// The inset from the row's leading edge to the rail.
    public static let activityHorizontalInset: Double = 8
    /// The inset from the body's trailing edge to the row's.
    public static let activityTrailingInset: Double = 8
    /// One activity row's own vertical padding, per edge. Small on purpose: this is the number
    /// that decides whether a screenful of machinery is four rows or fourteen.
    public static let activityRowPadding: Double = 3
    /// The `… +N lines` / `− show less` line under a bounded body.
    public static let trailerHeight: Double = 17
    /// The right-hand column holding a row's timestamp. It shares the row rather than occupying a
    /// line of its own — a timestamp on its own line costs one line per row, which over a session
    /// is more vertical space than every tool result put together.
    public static let timeColumnWidth: Double = 38

    // MARK: - Prose and bubbles

    /// Claude's own reply gets room to breathe, since it is what a reader actually reads.
    public static let proseRowPadding: Double = 10
    /// A bubble's own padding — a user, relayed, resent or command-with-args bubble has no header,
    /// just padding around its text.
    public static let bubbleVerticalPadding: Double = 10
    /// The vertical padding around a `me` row, outside the bubble itself.
    public static let meRowPadding: Double = 6
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

    // MARK: - Horizontal insets

    /// Every bubble-shaped card's own `.padding(.horizontal, bubbleHorizontalPadding)`.
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
    /// A fixed reserved gap on the leading edge of every right-aligned bubble — what stops a long
    /// message going edge-to-edge and gives the eye a gutter to read which side it is addressed
    /// from, serving the same purpose as the web's `max-w-[80%]` without copying its percentage. A
    /// fixed point value rather than a fraction of the row's own width, so the view (a `.padding`)
    /// and the measurer (a width subtraction) compute it from the exact same number rather than
    /// two formulas that could drift apart.
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

/// One card of a row, measured — the single answer both the height and the drawing view read.
///
/// Whether a clamped body actually overflowed is a *measured* fact, not a guess, and it decides
/// two things at once: whether the row reserves a trailer line, and whether the view draws one. A
/// view deriving that itself from the same text would be the same conclusion computed twice, which
/// is exactly how a drawn row comes to disagree with its own measured height.
public struct MeasuredCard: Sendable, Equatable {
    public let plan: TranscriptCardPlan
    /// This card's top, relative to the row's own top.
    public let offset: Double
    /// This card's total height, chrome included.
    public let height: Double
    /// The content's height after the visual cap — what the view must clip to.
    public let contentHeight: Double
    /// Whether anything was cut: either source lines were sliced away, or the visual cap bit.
    /// The trailer exists if and only if this is true.
    public let isTruncated: Bool
    /// Each block's top, relative to the start of this card's content.
    public let blockOffsets: [Double]

    public init(
        plan: TranscriptCardPlan, offset: Double, height: Double, contentHeight: Double, isTruncated: Bool,
        blockOffsets: [Double]
    ) {
        self.plan = plan
        self.offset = offset
        self.height = height
        self.contentHeight = contentHeight
        self.isTruncated = isTruncated
        self.blockOffsets = blockOffsets
    }
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

    /// Every card of `message`, measured in order. Empty for a message that renders nothing.
    ///
    /// This is the one measurement pass. ``height(for:width:environment:isRevealed:measurer:cache:metrics:)``
    /// sums it and the drawing view consumes it, so a row's drawn height and its laid-out height
    /// come from the same arithmetic rather than from two readings of the same rules.
    public static func measure(
        for message: Message,
        width: Double,
        environment: MeasurementEnvironment,
        isRevealed: (Int) -> Bool,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache,
        metrics: MessageLayoutMetrics
    ) -> [MeasuredCard] {
        let cards = TranscriptRowPlan.cards(for: message, isRevealed: isRevealed)
        var measured: [MeasuredCard] = []
        measured.reserveCapacity(cards.count)

        var cursor: Double = 0
        for card in cards {
            let content = MessageContentLayoutComposer.layout(
                of: card.blocks, width: contentWidth(for: card.register, cellWidth: width),
                environment: environment, metrics: metrics, measurer: measurer, cache: cache)

            let cap = visualCap(for: card, metrics: metrics)
            let clamped = cap.map { min(content.totalHeight, $0) } ?? content.totalHeight
            // Truncated by any of the three: source lines cut before measuring, text trimmed
            // because the body could never fit the clamp, or a cap genuinely shorter than what the
            // body laid out to.
            let isTruncated =
                card.preview.hiddenLines > 0 || card.preview.wasTrimmed
                || (cap != nil && content.totalHeight > clamped)

            let height = cardHeight(
                of: card, content: clamped, isTruncated: isTruncated, cellWidth: width, metrics: metrics)

            measured.append(
                MeasuredCard(
                    plan: card, offset: cursor, height: height, contentHeight: clamped,
                    isTruncated: isTruncated, blockOffsets: content.blocks.map(\.offset)))
            cursor += height
        }
        return measured
    }

    /// `nil` for a message whose plan is empty — a route that renders nothing at all. A caller
    /// filters those out of the row list; this never hands back a height of `0` for a row that is
    /// still supposed to occupy a cell.
    public static func height(
        for message: Message,
        width: Double,
        environment: MeasurementEnvironment,
        isRevealed: (Int) -> Bool,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache,
        metrics: MessageLayoutMetrics
    ) -> Double? {
        let cards = measure(
            for: message, width: width, environment: environment, isRevealed: isRevealed, measurer: measurer,
            cache: cache, metrics: metrics)
        guard !cards.isEmpty else { return nil }
        return cards.reduce(0) { $0 + $1.height }
    }

    /// The vertical distance from the top of `message`'s row to the top of one block inside one
    /// of its cards — the same origin and units ``height(for:width:environment:isRevealed:measurer:cache:metrics:)``'s
    /// own total is in.
    ///
    /// Exists because landing a search hit on screen cannot stop at "scroll to this row": a real
    /// row can run to thousands of points (one agent report in a real transcript measures
    /// 12382px), and scrolling only to its top would not bring a hit deep inside it into view.
    /// This gives the exact point within the row without needing character-level access to the
    /// text a cell draws — the block it is in is already known and already measured.
    ///
    /// `nil` when `cardIndex` is out of range for `message`'s current plan; `blockIndex` out of
    /// range degrades to the top of the card's own content rather than failing — a caller reveals
    /// the card before asking this, but a stale index should land somewhere reasonable.
    public static func blockOffset(
        cardIndex: Int,
        blockIndex: Int,
        for message: Message,
        width: Double,
        environment: MeasurementEnvironment,
        isRevealed: (Int) -> Bool,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache,
        metrics: MessageLayoutMetrics
    ) -> Double? {
        let cards = measure(
            for: message, width: width, environment: environment, isRevealed: isRevealed, measurer: measurer,
            cache: cache, metrics: metrics)
        guard cards.indices.contains(cardIndex) else { return nil }

        let card = cards[cardIndex]
        var total = card.offset + chromeBeforeContent(of: card.plan, metrics: metrics)
        if card.blockOffsets.indices.contains(blockIndex) {
            total += card.blockOffsets[blockIndex]
        }
        return total
    }

    /// The visual cap a card's content is clipped to, or `nil` when nothing clips it.
    ///
    /// A line limit's height is exactly `lines × lineHeight` because that is what the drawing
    /// view's own `.lineLimit` produces from the same font — the line heights come from the
    /// measurer's fonts through ``MessageLayoutMetrics``, never from a number written down twice.
    private static func visualCap(for card: TranscriptCardPlan, metrics: MessageLayoutMetrics) -> Double? {
        guard let lines = card.preview.visualLines else { return nil }
        switch card.register {
        case .prose:
            return Double(lines) * metrics.proseLineHeight
        case .me:
            return Double(lines) * metrics.proseLineHeight + TranscriptRowMetrics.bubbleVerticalPadding
        case .activity:
            // A code block's padding sits inside the box it draws, so the cap has to allow for it
            // or the clip eats a line of text rather than the slack under it.
            return Double(lines) * metrics.activityLineHeight + 2 * TranscriptRowMetrics.codeBlockPadding
        }
    }

    /// Distance from a card's own top edge to the top of its measured content — the counterpart
    /// to what ``cardHeight(of:content:isTruncated:cellWidth:metrics:)`` adds *after* the content
    /// for that same register, kept as its own function so the two can never quietly drift onto
    /// different numbers for the same chrome.
    private static func chromeBeforeContent(of card: TranscriptCardPlan, metrics: MessageLayoutMetrics) -> Double {
        switch card.register {
        case .activity:
            // The label line sits above the body, so a hit inside the body is one line further
            // down than the row's own padding — omitting it lands every activity-row hit high.
            return TranscriptRowMetrics.activityRowPadding + metrics.activityLineHeight
        case .prose:
            return TranscriptRowMetrics.proseRowPadding
        case .me:
            switch card.kind {
            case .relayedBubble, .command, .resentUserBubble:
                return TranscriptRowMetrics.meRowPadding + TranscriptRowMetrics.bubbleLabelLineHeight
                    + TranscriptRowMetrics.bubbleLabelSpacing + TranscriptRowMetrics.bubbleVerticalPadding / 2
            default:
                return TranscriptRowMetrics.meRowPadding + TranscriptRowMetrics.bubbleVerticalPadding / 2
            }
        }
    }

    /// The width `card`'s own text wraps at — the cell width minus whichever horizontal chrome the
    /// view draws that register inside, so a wrap this measures and a wrap the view lays out can
    /// never be computed from two different widths.
    private static func contentWidth(for register: TranscriptCardPlan.Register, cellWidth: Double) -> Double {
        switch register {
        case .activity:
            return max(
                0,
                cellWidth - TranscriptRowMetrics.activityHorizontalInset - TranscriptRowMetrics.railWidth
                    - TranscriptRowMetrics.markerColumnWidth - TranscriptRowMetrics.gridGap
                    - TranscriptRowMetrics.gridGap - TranscriptRowMetrics.timeColumnWidth
                    - TranscriptRowMetrics.activityTrailingInset)
        case .prose:
            // Full width, deliberately: Claude's reply is the longest text on screen and a
            // container around it only narrows what there is to read.
            return max(
                0,
                cellWidth - TranscriptRowMetrics.activityHorizontalInset - TranscriptRowMetrics.gridGap
                    - TranscriptRowMetrics.timeColumnWidth - TranscriptRowMetrics.activityTrailingInset)
        case .me:
            // The row's own chrome first — a bubble sits inside `MeRowView`, which already spent
            // the inset, the gap and the time column — and only then the bubble's own gutter and
            // padding. Measuring at the bubble's share of the WHOLE cell wraps the text wider than
            // it draws, which is a row measured shorter than it is.
            return max(
                0,
                cellWidth - TranscriptRowMetrics.activityHorizontalInset - TranscriptRowMetrics.gridGap
                    - TranscriptRowMetrics.timeColumnWidth - TranscriptRowMetrics.activityTrailingInset
                    - TranscriptRowMetrics.bubbleGutter - 2 * TranscriptRowMetrics.bubbleHorizontalPadding)
        }
    }

    private static func cardHeight(
        of card: TranscriptCardPlan, content: Double, isTruncated: Bool, cellWidth: Double,
        metrics: MessageLayoutMetrics
    ) -> Double {
        let labelChrome = TranscriptRowMetrics.bubbleLabelLineHeight + TranscriptRowMetrics.bubbleLabelSpacing

        switch card.register {
        case .activity:
            // Label line, body, trailer — the label is always drawn and always exactly one line,
            // because it is pinned to `.lineLimit(1)` in the view. The timestamp shares the row
            // rather than adding a line of its own.
            return TranscriptRowMetrics.activityRowPadding * 2
                + metrics.activityLineHeight
                + content
                + (isTruncated ? TranscriptRowMetrics.trailerHeight : 0)

        case .prose:
            switch card.kind {
            case .assistantBubble(let text, let filePaths):
                let hasText = !text.isEmpty
                let chips = Double(filePaths.count) * TranscriptRowMetrics.attachmentChipHeight
                let childCount = (hasText ? 1 : 0) + filePaths.count
                let gaps = childCount > 1 ? Double(childCount - 1) * TranscriptRowMetrics.attachmentChipSpacing : 0
                return TranscriptRowMetrics.proseRowPadding * 2 + (hasText ? content : 0) + chips + gaps
            default:
                return TranscriptRowMetrics.proseRowPadding * 2 + content
            }

        case .me:
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
                let gaps = childCount > 1 ? Double(childCount - 1) * TranscriptRowMetrics.attachmentChipSpacing : 0
                return TranscriptRowMetrics.meRowPadding * 2 + textHeight + chips + gaps

            case .relayedBubble(let text, _, _):
                return TranscriptRowMetrics.meRowPadding * 2 + (text.isEmpty ? 0 : content) + labelChrome
                    + TranscriptRowMetrics.bubbleVerticalPadding

            case .resentUserBubble(let text, let attachmentPaths):
                // Mirrors `.userBubble` exactly, not `.relayedBubble`: the label+bubble only exist
                // when there's text to caption, so an attachment-only resend draws exactly like a
                // plain attachment-only send — no bubble, no label.
                let hasText = !text.isEmpty
                let bubbleHeight = hasText ? content + labelChrome + TranscriptRowMetrics.bubbleVerticalPadding : 0
                let chips = Double(attachmentPaths.count) * TranscriptRowMetrics.attachmentChipHeight
                let childCount = (hasText ? 1 : 0) + attachmentPaths.count
                let gaps = childCount > 1 ? Double(childCount - 1) * TranscriptRowMetrics.attachmentChipSpacing : 0
                return TranscriptRowMetrics.meRowPadding * 2 + bubbleHeight + chips + gaps

            case .command(_, let args):
                // No arguments degrades to a compact line naming the command and nothing else.
                guard args != nil else {
                    return TranscriptRowMetrics.meRowPadding * 2 + TranscriptRowMetrics.bubbleLabelLineHeight
                        + TranscriptRowMetrics.bubbleVerticalPadding
                }
                return TranscriptRowMetrics.meRowPadding * 2 + content + labelChrome
                    + TranscriptRowMetrics.bubbleVerticalPadding
                    + (isTruncated ? TranscriptRowMetrics.trailerHeight : 0)

            default:
                return TranscriptRowMetrics.meRowPadding * 2 + content
                    + TranscriptRowMetrics.bubbleVerticalPadding
            }
        }
    }
}
