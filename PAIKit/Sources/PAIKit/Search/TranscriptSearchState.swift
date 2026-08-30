import Foundation
import Observation

/// Where a transcript search currently stands: whether it is open, what it is looking for, every
/// occurrence found and which one is current.
///
/// Holds no reference to messages, the store or the collection view — it is handed a finished
/// result set (``setResults(hits:truncated:readerMessageId:)``) by whatever owns fetching and
/// indexing them, the same split ``TranscriptWindow`` draws between state and the fetch that
/// fills it. That keeps navigation — stepping, wrapping, picking a start position — a pure
/// function over data this type already has, provable without a collection view or a network
/// call.
///
/// `@MainActor`, not an actor, matching ``TranscriptStore``: every realistic caller is UI-driven.
@MainActor
@Observable
public final class TranscriptSearchState {
    public private(set) var isActive = false
    public var query = ""
    public private(set) var hits: [TranscriptSearchHit] = []
    /// Whether ``TranscriptSearchIndex/maxHits`` was reached — the result set is real but
    /// incomplete, and the reader should be told rather than shown a count that looks final.
    public private(set) var truncated = false
    public private(set) var activeHitIndex: Int?
    /// Set by whoever owns fetching while a full-history load is filling in messages this search
    /// cannot see yet — a bounded window is exactly what the row's own note calls out: "a bounded
    /// window triggers a full-history load before searching."
    public var isLoadingFullHistory = false

    public init() {}

    public var currentHit: TranscriptSearchHit? {
        activeHitIndex.map { hits[$0] }
    }

    /// `nil` while there is nothing to say yet — an empty query, or hits still loading.
    public var resultsSummary: String? {
        guard !query.isEmpty, !isLoadingFullHistory else { return nil }
        guard let activeHitIndex else { return hits.isEmpty ? "No results" : nil }
        let total = truncated ? "\(hits.count)+" : "\(hits.count)"
        return "\(activeHitIndex + 1)/\(total)"
    }

    public func open() {
        isActive = true
    }

    public func close() {
        isActive = false
        query = ""
        hits = []
        truncated = false
        activeHitIndex = nil
        isLoadingFullHistory = false
    }

    /// Replaces the result set — called once a query's hits have been computed — and picks a
    /// starting position: the first hit at or after `readerMessageId`, else the last one before
    /// it. Matches the web: search opens at the reader's own position, not the top of a
    /// three-hour transcript.
    public func setResults(hits: [TranscriptSearchHit], truncated: Bool, readerMessageId: Int?) {
        self.hits = hits
        self.truncated = truncated
        activeHitIndex = Self.startIndex(in: hits, atOrAfterMessageId: readerMessageId)
    }

    public func next() {
        guard !hits.isEmpty else { return }
        activeHitIndex = ((activeHitIndex ?? -1) + 1) % hits.count
    }

    public func previous() {
        guard !hits.isEmpty else { return }
        activeHitIndex = ((activeHitIndex ?? 0) - 1 + hits.count) % hits.count
    }

    /// `hits` must already be in render order (``TranscriptSearchIndex/hits(in:query:)``'s own
    /// contract) — this walks it once rather than sorting, since the caller's order is already
    /// the one that matters.
    static func startIndex(in hits: [TranscriptSearchHit], atOrAfterMessageId messageId: Int?) -> Int? {
        guard !hits.isEmpty else { return nil }
        guard let messageId else { return 0 }
        if let atOrAfter = hits.firstIndex(where: { $0.messageId >= messageId }) {
            return atOrAfter
        }
        return hits.count - 1
    }
}
