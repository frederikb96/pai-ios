import Foundation
import Observation

/// Where a transcript search currently stands — the `find`/`locate`/`reveal`/`mark` pipeline's
/// own presentation state (search-virtualization design). Swift port of the web's `FindState`.
///
/// Holds no reference to messages, the store, the network or the collection view — every action
/// with a side effect beyond this type's own fields (a `find` round trip, a `locate`+`reveal`) is
/// a request recorded here and drained by whoever owns those capabilities
/// (`TranscriptCollectionViewController`), the same split ``TranscriptWindow`` draws between
/// state and the fetch that fills it, and the same shape ``TranscriptJumpRequests`` already uses
/// for a deep link reaching an already-open screen. `TranscriptSearchBar` — a SIBLING view under
/// the same `SessionDetailView`, never a parent or child of the collection view — writes `query`/
/// `kind`/``requestNext()``/``requestPrevious()`` directly and reads everything else; the
/// collection view watches every field via `withObservationTracking` and drains the requests. That
/// split is what keeps navigation DECISIONS (stepping, wrapping) pure functions over data this
/// type already has — provable without a collection view or a network call — while the actual
/// fetch stays with whatever holds an API client.
///
/// `@MainActor`, not an actor, matching ``TranscriptStore``: every realistic caller is UI-driven.
@MainActor
@Observable
public final class TranscriptSearchState {
    public private(set) var isActive = false
    /// Written directly by the search bar on every keystroke — debouncing a `find` request off
    /// this belongs to whoever drives the network, not to this type.
    public var query = ""
    /// `nil` in text mode. Written directly by the search bar; mutually exclusive with a
    /// non-empty `query` in the same way the web's own bar keeps them (typing clears a selected
    /// kind and vice versa) — enforced by the bar, since this type only ever reflects whichever
    /// mode was last written.
    public var kind: MessageKind?
    public private(set) var loading = false
    public private(set) var error: String?
    /// Exact count of the whole match, independent of the cap.
    public private(set) var total = 0
    public private(set) var capped = false
    /// 0-based position in the hit list, `nil` when there is no current hit.
    public private(set) var outerIndex: Int?
    public private(set) var currentMessageId: Int?
    /// The occurrence within the current message, or `nil` when there is nothing to show for it
    /// — a kind hit (no needle at all), or a text hit that resolved to zero occurrences in the
    /// loaded, rendered text (the term sat in a field the client does not render; the row still
    /// counts at the outer level, only the inner counter hides).
    public private(set) var inner: (ordinal: Int, count: Int)?
    /// Ids worth highlighting right now — the server list once `find` has answered (kind mode),
    /// or a client-side stand-in (whatever loaded message already contains the query) while a
    /// text search is still in flight, so perceived latency for what's on screen is zero.
    public private(set) var matchedIds: Set<Int> = []

    public enum PendingStep: Equatable { case next, previous }
    /// Set by the bar's stepping buttons, drained by the collection view — see this type's own
    /// doc comment for why a request/drain field replaces a direct call here: deciding what a
    /// step even means can require a `locate`, which needs the network.
    public private(set) var pendingStep: PendingStep?

    public init() {}

    public var currentHit: (messageId: Int, inner: (ordinal: Int, count: Int)?)? {
        guard let currentMessageId else { return nil }
        return (currentMessageId, inner)
    }

    /// `nil` while there is nothing to say yet — an empty query/kind, or a request in flight.
    public var resultsSummary: String? {
        guard hasQuery, !loading else { return nil }
        guard let outerIndex else { return total == 0 ? "No results" : nil }
        let totalText = capped ? "\(total)+" : "\(total)"
        return "\(outerIndex + 1)/\(totalText)"
    }

    private var hasQuery: Bool {
        !query.isEmpty || kind != nil
    }

    public func open() {
        isActive = true
    }

    public func close() {
        isActive = false
        query = ""
        kind = nil
        loading = false
        error = nil
        total = 0
        capped = false
        outerIndex = nil
        currentMessageId = nil
        inner = nil
        matchedIds = []
        pendingStep = nil
    }

    public func requestNext() {
        pendingStep = .next
    }

    public func requestPrevious() {
        pendingStep = .previous
    }

    /// Consumed once — returns whatever was pending and clears it, so the same request is never
    /// drained twice.
    public func consumePendingStep() -> PendingStep? {
        defer { pendingStep = nil }
        return pendingStep
    }

    /// A new find request is about to be sent — mirrors the web's very first `setState` in
    /// `runFind`: loading shown, and whatever is already loaded that matches painted immediately
    /// rather than waiting on the round trip. Reads the CURRENT `query`/`kind` rather than taking
    /// them as parameters — the bar already committed both before this runs.
    public func beginFind(instantMatchedIds: Set<Int>) {
        loading = true
        error = nil
        matchedIds = instantMatchedIds
    }

    /// The query and kind are both empty — nothing to search, matching the web's own early
    /// return in `runFind`. Resets every result field but leaves `query`/`kind` alone: they are
    /// the bar's own input, not this action's to touch.
    public func clearResults() {
        loading = false
        error = nil
        total = 0
        capped = false
        outerIndex = nil
        currentMessageId = nil
        inner = nil
        matchedIds = []
    }

    /// `find` answered. `serverMatchedIds` replaces `matchedIds` outright in kind mode (there is
    /// no client-side instant match for a kind, only for text) — in text mode the instant
    /// client-side set already showing is left alone, matching the web's own
    /// `matchedIds: query ? s.matchedIds : new Set(result.message_ids)`.
    public func applyFindResult(total: Int, capped: Bool, serverMatchedIdsForKindMode: [Int]?) {
        loading = false
        self.total = total
        self.capped = capped
        if let serverMatchedIdsForKindMode {
            matchedIds = Set(serverMatchedIdsForKindMode)
        }
    }

    public func setError(_ message: String) {
        loading = false
        error = message
    }

    /// `landOn` positioned the reader on a hit — commits the new outer/inner position.
    public func commitLanding(outerIndex: Int, messageId: Int, inner: (ordinal: Int, count: Int)?) {
        self.outerIndex = outerIndex
        self.currentMessageId = messageId
        self.inner = inner
    }

    /// Steps the inner ordinal in place, without moving the outer index or re-locating anything
    /// — the fast path ``next(hitCount:)``/``previous(hitCount:)`` chooses when the current
    /// message still has more occurrences of its own.
    public func stepInner(to ordinal: Int) {
        guard let inner else { return }
        self.inner = (ordinal, inner.count)
    }

    /// What a step should do — decided here so it is provable without a collection view or a
    /// network call, mirroring the web's `next()`/`prev()` split: step the inner ordinal first;
    /// only once it runs out does the outer cursor advance, wrapping around the hit list the
    /// same way the stepping chevrons always have.
    ///
    /// `hitCount` is the LOADED hit-id list's own length, never `total` — the two differ exactly
    /// when `capped` is true, and wrapping against the wrong one would step past ids that were
    /// never fetched.
    public enum Step: Equatable {
        case none
        case innerOnly(ordinal: Int)
        case outerIndex(Int)
    }

    public func next(hitCount: Int) -> Step {
        guard hitCount > 0 else { return .none }
        if !query.isEmpty, let inner, inner.ordinal + 1 < inner.count {
            return .innerOnly(ordinal: inner.ordinal + 1)
        }
        let nextIndex = ((outerIndex ?? -1) + 1) % hitCount
        return .outerIndex(nextIndex)
    }

    public func previous(hitCount: Int) -> Step {
        guard hitCount > 0 else { return .none }
        if !query.isEmpty, let inner, inner.ordinal > 0 {
            return .innerOnly(ordinal: inner.ordinal - 1)
        }
        let prevIndex = ((outerIndex ?? 0) - 1 + hitCount) % hitCount
        return .outerIndex(prevIndex)
    }
}
