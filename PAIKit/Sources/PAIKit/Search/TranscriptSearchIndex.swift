import Foundation

/// One occurrence of a search term inside the transcript — the atomic unit search counts and
/// steps through. A message is too coarse a unit on its own: one assistant turn can be twenty
/// screens tall and hold the term a dozen times.
public struct TranscriptSearchHit: Equatable, Sendable {
    public let messageId: Int
    /// Index into ``TranscriptRowPlan/cards(for:isRevealed:)`` for ``messageId``. Stable
    /// regardless of reveal state — revealing a card changes its `blocks`, never which cards
    /// exist or their order, so this index means the same thing whether the card that produced it
    /// was bounded or open at the time. It is also the key reveal itself is stored under, so a hit
    /// already carries everything needed to open the card it landed in.
    public let cardIndex: Int
    /// Index into `card.blocks` — a bounded card holds only the text it shows, so a hit past the
    /// preview is only reachable once its card is revealed.
    public let blockIndex: Int
    /// UTF-16 range within `card.blocks[blockIndex].plainText`.
    public let range: NSRange

    public init(messageId: Int, cardIndex: Int, blockIndex: Int, range: NSRange) {
        self.messageId = messageId
        self.cardIndex = cardIndex
        self.blockIndex = blockIndex
        self.range = range
    }
}

/// Builds every ``TranscriptSearchHit`` in a loaded window of messages.
///
/// Ported from `searchText.ts`'s role, not its code: the store is the only thing that knows about
/// text behind a bounded preview, so this always calls
/// ``TranscriptRowPlan/cards(for:isRevealed:)`` with every card forced open — never the resolver
/// a real render uses — so a truncated tool result is still searchable. That is safe because
/// `TranscriptRowPlan` guarantees the cards it produces never depend on reveal state, only their
/// `blocks` do (see that type's own doc comment): indexing against a forced-open call and later
/// rendering against the real one agree by construction once a hit's own card is actually opened.
public enum TranscriptSearchIndex {
    /// Mirrors the web's `MAX_HITS` — a transcript search caps out rather than growing unbounded
    /// navigation over a session with the term on every line.
    public static let maxHits = 5000

    private static let alwaysRevealed: @Sendable (Int) -> Bool = { _ in true }

    /// `messages` must already be the ascending, display-filtered window a caller would render —
    /// this neither filters nor sorts, so render order and hit order agree by construction.
    public static func hits(in messages: [Message], query: String) -> (hits: [TranscriptSearchHit], truncated: Bool) {
        guard !SearchText.normalize(query).isEmpty else { return ([], false) }

        var result: [TranscriptSearchHit] = []
        outer: for message in messages {
            let cards = TranscriptRowPlan.cards(for: message, isRevealed: alwaysRevealed)
            for (cardIndex, card) in cards.enumerated() {
                for (blockIndex, block) in card.blocks.enumerated() {
                    for range in SearchText.findMatches(in: block.plainText, query: query) {
                        result.append(
                            TranscriptSearchHit(
                                messageId: message.id, cardIndex: cardIndex,
                                blockIndex: blockIndex, range: range))
                        if result.count >= maxHits { break outer }
                    }
                }
            }
        }
        return (result, result.count >= maxHits)
    }
}
