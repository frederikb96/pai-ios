import Foundation

/// The recursive geometry a `.list` or a `.blockQuote` measures its own nested blocks at.
///
/// Kept out of `TextKitBlockMeasurer` on purpose, even though that is its only real caller: which
/// width a nesting level draws at and which gaps apply between its items is pure arithmetic, and
/// putting it here — Apple-agnostic, next to ``MessageContentLayoutComposer`` — makes it provable
/// against a stub ``BlockMeasuring`` on Linux. Only the leaf measurement of an actual run of text
/// needs TextKit; a `TextKitBlockMeasurer` that calls back into this with itself as `measurer`
/// gets nesting for free, at the cost of not being the thing this proves.
///
/// Mirrors `MarkdownContentView`'s own view structure exactly: a `.list` is a `VStack` of items,
/// each an `HStack` of a marker and a recursive `MarkdownContentView` over that item's own blocks;
/// a `.blockQuote` is an `HStack` of a rule and one recursive `MarkdownContentView`. Both existed
/// before this type as a single flattened `NSAttributedString` measured once at the *outer*
/// width — correct only for a list or quote with no nested list or quote inside it, and
/// increasingly wrong by one more inset per level of nesting past that.
public enum NestedBlockLayout {

    /// `width` is the width the `.list` itself is drawn at, before its own inset — never an
    /// already-narrowed width, since narrowing happens here.
    public static func listHeight(
        _ list: MarkdownList, width: Double, environment: MeasurementEnvironment, measurer: some BlockMeasuring
    ) -> Double {
        guard !list.items.isEmpty else { return 0 }
        let itemWidth = max(
            0, width - TranscriptRowMetrics.listMarkerReservedWidth - TranscriptRowMetrics.listMarkerSpacing)
        var total: Double = 0
        for (index, item) in list.items.enumerated() {
            if index > 0 { total += TranscriptRowMetrics.listItemSpacing }
            total += blocksHeight(item.blocks, width: itemWidth, environment: environment, measurer: measurer)
        }
        return total
    }

    /// `width` is the width the `.blockQuote` itself is drawn at, before its own inset.
    public static func blockQuoteHeight(
        _ blocks: [MarkdownBlock], width: Double, environment: MeasurementEnvironment, measurer: some BlockMeasuring
    ) -> Double {
        let innerWidth = max(
            0, width - TranscriptRowMetrics.blockQuoteRuleWidth - TranscriptRowMetrics.blockQuoteSpacing)
        return blocksHeight(blocks, width: innerWidth, environment: environment, measurer: measurer)
    }

    /// Sums a list item's or a block quote's own blocks the way `MarkdownContentView` stacks
    /// them: each measured through `measurer` at this level's already-narrowed width — recursing
    /// again through this same type when one of them is itself a further-nested list or quote —
    /// separated by ``TranscriptRowMetrics/markdownBlockSpacing``, the identical gap the view's
    /// own `VStack` puts between them.
    private static func blocksHeight(
        _ blocks: [MarkdownBlock], width: Double, environment: MeasurementEnvironment, measurer: some BlockMeasuring
    ) -> Double {
        var total: Double = 0
        for (index, block) in blocks.enumerated() {
            if index > 0 { total += TranscriptRowMetrics.markdownBlockSpacing }
            total += measurer.height(of: block, width: width, environment: environment)
        }
        return total
    }
}
