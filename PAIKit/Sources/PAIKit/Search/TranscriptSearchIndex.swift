import Foundation

/// One occurrence of a search term inside the transcript — the atomic unit search counts and
/// steps through. A message is too coarse a unit on its own: one assistant turn can be twenty
/// screens tall and hold the term a dozen times.
public struct TranscriptSearchHit: Equatable, Sendable {
    public let messageId: Int
    /// Index into ``TranscriptRowPlan/cards(for:isExpanded:)`` for ``messageId``. Stable
    /// regardless of expand state — a card's expansion changes its `blocks`, never which cards
    /// exist or their order, so this index means the same thing whether the card that produced it
    /// was collapsed or open at the time.
    public let cardIndex: Int
    /// The key that opens this hit's card, or `nil` for one that is never collapsible (a plain
    /// bubble, a command's own arguments) and therefore always visible already.
    public let expandKey: String?
    /// Index into `card.blocks` — only meaningful once the card is actually expanded, since a
    /// collapsed card's `blocks` is empty.
    public let blockIndex: Int
    /// UTF-16 range within `card.blocks[blockIndex].plainText`.
    public let range: NSRange

    public init(messageId: Int, cardIndex: Int, expandKey: String?, blockIndex: Int, range: NSRange) {
        self.messageId = messageId
        self.cardIndex = cardIndex
        self.expandKey = expandKey
        self.blockIndex = blockIndex
        self.range = range
    }
}

/// Builds every ``TranscriptSearchHit`` in a loaded window of messages.
///
/// Ported from `searchText.ts`'s role, not its code: the store is the only thing that knows about
/// text behind a collapsed card, so this always calls
/// ``TranscriptRowPlan/cards(for:isExpanded:)`` with every card forced open — never the resolver
/// a real render uses — so a collapsed tool result is still searchable. That is safe because
/// `TranscriptRowPlan` guarantees the cards it produces never depend on expand state, only their
/// `blocks` do (see that type's own doc comment): indexing against a forced-open call and later
/// rendering against the real one agree by construction once a hit's own card is actually opened.
public enum TranscriptSearchIndex {
    /// Mirrors the web's `MAX_HITS` — a transcript search caps out rather than growing unbounded
    /// navigation over a session with the term on every line.
    public static let maxHits = 5000

    private static let alwaysExpanded: @Sendable (String) -> Bool = { _ in true }

    /// `messages` must already be the ascending, display-filtered window a caller would render —
    /// this neither filters nor sorts, so render order and hit order agree by construction.
    public static func hits(in messages: [Message], query: String) -> (hits: [TranscriptSearchHit], truncated: Bool) {
        guard !SearchText.normalize(query).isEmpty else { return ([], false) }

        var result: [TranscriptSearchHit] = []
        outer: for message in messages {
            let cards = TranscriptRowPlan.cards(for: message, isExpanded: alwaysExpanded)
            for (cardIndex, card) in cards.enumerated() {
                for (blockIndex, block) in card.blocks.enumerated() {
                    for range in SearchText.findMatches(in: block.plainText, query: query) {
                        result.append(
                            TranscriptSearchHit(
                                messageId: message.id, cardIndex: cardIndex, expandKey: card.expandKey,
                                blockIndex: blockIndex, range: range))
                        if result.count >= maxHits { break outer }
                    }
                }
            }
        }
        return (result, result.count >= maxHits)
    }
}
