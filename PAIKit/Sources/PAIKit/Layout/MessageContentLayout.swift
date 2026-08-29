import Foundation

/// The measured layout of one message's markdown content: a total height, and the height and
/// vertical offset of every block that makes it up, in order.
///
/// Per-block offsets are kept rather than thrown away after summing, because a GFM table is its
/// own measured subview rather than part of an attributed string — whatever positions that
/// subview inside the message needs to know exactly where its block starts, not just the
/// message's total height.
public struct MessageContentLayout: Hashable, Sendable {
    public struct BlockLayout: Hashable, Sendable {
        public let block: MarkdownBlock
        /// Distance from the top of the message content to the top of this block.
        public let offset: Double
        public let height: Double

        public init(block: MarkdownBlock, offset: Double, height: Double) {
            self.block = block
            self.offset = offset
            self.height = height
        }
    }

    public let blocks: [BlockLayout]
    public let totalHeight: Double

    public init(blocks: [BlockLayout], totalHeight: Double) {
        self.blocks = blocks
        self.totalHeight = totalHeight
    }
}

/// The spacing applied between the blocks of one message's content.
///
/// A parameter rather than a constant defined here: the actual value is a design-token decision
/// that belongs with the card chrome wrapping this content, not with the arithmetic that applies
/// it once decided.
public struct MessageLayoutMetrics: Sendable {
    public let blockSpacing: Double

    public init(blockSpacing: Double) {
        self.blockSpacing = blockSpacing
    }
}

/// Composes a message's blocks into one measured, exact layout.
///
/// Deliberately not itself cached beyond the per-block ``BlockHeightCache`` it is handed: summing
/// a handful of already-cached lookups is a cheap array pass. A second cache layer over the total
/// would only be worth its complexity if that pass measurably cost something — nothing here has
/// shown it does, and adding one speculatively would be the cascading-cache-layers version of a
/// premature optimization.
///
/// Expansion state — a tool card collapsed versus expanded — is not a parameter here, on purpose.
/// A collapsed card and an expanded one measure differently because the **caller passes a
/// different array of blocks**, not because this function treats one fixed array differently
/// depending on an extra flag. That keeps "what is expanded" living in exactly one place, the
/// caller's choice of what to lay out, instead of duplicating it into a second identity here that
/// could disagree with the first.
public enum MessageContentLayoutComposer {
    public static func layout(
        of blocks: [MarkdownBlock],
        width: Double,
        environment: MeasurementEnvironment,
        metrics: MessageLayoutMetrics,
        measurer: some BlockMeasuring,
        cache: BlockHeightCache
    ) -> MessageContentLayout {
        var laidOut: [MessageContentLayout.BlockLayout] = []
        laidOut.reserveCapacity(blocks.count)

        var cursor: Double = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 { cursor += metrics.blockSpacing }
            let height = cache.height(of: block, width: width, environment: environment, measurer: measurer)
            laidOut.append(MessageContentLayout.BlockLayout(block: block, offset: cursor, height: height))
            cursor += height
        }

        return MessageContentLayout(blocks: laidOut, totalHeight: cursor)
    }
}
