import Foundation
import Observation

/// The per-session message window: what is loaded, how it pages backwards, and how the tail SSE
/// stream and REST paging both feed it.
///
/// Swift port of `pai-cloud/web/src/stores/messages.ts`. This type only ever *applies* entries
/// someone else fetched — bootstrapping, paging and connecting the stream are lifecycle-driven
/// (view appears, session switches, view disappears) and belong to whatever owns that lifecycle;
/// see `PaiApiClient.getMessages` and `PaiSseClient`, both already built, for the calls that feed
/// this store's `apply…` methods.
///
/// `@MainActor`, not an actor: every realistic caller is UI-driven, and `PaiSseClient`'s own
/// callbacks already arrive on the main actor for the same reason (see its doc comment).
@MainActor
@Observable
public final class TranscriptStore {

    /// Rows fetched by the tail bootstrap. Generous on purpose — many screens of context past
    /// any plausible "scroll up to re-read" — while still bounding a multi-MB session to a
    /// sub-second load.
    public static let tailLimit = 300
    public static let olderPageLimit = 150
    private static let maxCachedSessions = 5

    public internal(set) var messages: [String: [Message]] = [:]
    public internal(set) var windows: [String: TranscriptWindow] = [:]
    /// Ids observed via SSE while a session's window is not at the tail (`window.hasNewer`) —
    /// appending them would open a gap between the loaded window and the new message, so they
    /// are held here by id instead. Only used for the "new below" count and to detect the race
    /// `loadNewer`'s catch-up step closes; never merged into `messages` directly — see
    /// `foldLiveEntries`.
    public internal(set) var pendingNewerIds: [String: Set<Int>] = [:]
    /// The last-observed context-window figure, per session. Keyed rather than a single scalar
    /// so switching to a session that has not reported one yet can never show a different
    /// session's number — a reader falls back to the session's own persisted token count
    /// instead, never to this map.
    public internal(set) var sessionTokens: [String: Int] = [:]
    /// Keyed like `sessionTokens` and for the same reason: a scalar here showed the previous
    /// session's connection/spinner state on screen until the newly-switched-to session's first
    /// status event arrived and overwrote it. Carries strictly more than a plain "socket is open"
    /// flag would — "a socket is open" and "content is actually flowing through it" are different
    /// questions, and a connection can sit open with nothing arriving, which is exactly the state
    /// a bare connected/disconnected flag reads identically to a healthy one.
    public internal(set) var sseActivity: [String: StreamActivity] = [:]
    public internal(set) var isProcessing: [String: Bool] = [:]
    /// The session-level half of the latest `status` event, keyed like `sessionTokens` — the
    /// live picture while this session's transcript is open, for whichever store owns the
    /// session list to route into its own rows. See `applySseStatus`.
    public internal(set) var liveStatus: [String: LiveSessionStatus] = [:]
    /// The latest `arc` SSE signal per session — see `ArcSignal`'s doc comment.
    public internal(set) var liveArc: [String: ArcSignal] = [:]

    // Send-tracking state (``PendingMessage``, ``TranscriptDelivery``) is declared here — a
    // stored property cannot live in an extension — and its behaviour lives in
    // `TranscriptStore+Send.swift`, kept separate for readability.
    var pendingMessages: [String: [PendingMessage]] = [:]
    var delivery: [String: TranscriptDelivery] = [:]
    var localBubbleCounter = 0

    /// Tracks access order for LRU eviction. The most recently touched session moves to the end;
    /// once more than ``maxCachedSessions`` are loaded, the oldest (first) is evicted.
    private var sessionAccessOrder: [String] = []

    public init() {}

    /// The session-level fields of an SSE `status` event, carried as one value so a reader of
    /// `liveStatus` gets a single change notification per event rather than three.
    public struct LiveSessionStatus: Sendable, Equatable {
        public let state: SessionState?
        public let blocker: Blocker?
        public let working: Bool?
        public let presenceState: SessionPresenceState?
        public let activityCounts: ActivityCounts?
    }

    /// The latest `arc` SSE signal for one session, carried with an incrementing `sequence`
    /// rather than the bare spec uuid — a reader wants "refetch, something changed" on EVERY
    /// event, including a second write to the same spec in a row, and `onChange(of:)` only fires
    /// on a value that differs from the last one it saw. A bare `specUuid` would collapse two
    /// such events into one observed change; the counter cannot.
    public struct ArcSignal: Sendable, Equatable {
        public let specUuid: String
        public let sequence: Int
    }

    public func window(for sessionId: String) -> TranscriptWindow {
        windows[sessionId] ?? .empty
    }

    public func sseActivity(for sessionId: String) -> StreamActivity {
        sseActivity[sessionId] ?? StreamActivity()
    }

    public func isProcessing(for sessionId: String) -> Bool {
        isProcessing[sessionId] ?? false
    }

    public func maxMessageId(for sessionId: String) -> Int? {
        messages[sessionId]?.last?.id
    }

    // MARK: - Bootstrap / paging

    public func setBootstrapping(_ sessionId: String) {
        var win = window(for: sessionId)
        win.bootstrapping = true
        win.bootstrapError = nil
        windows[sessionId] = win
    }

    public func setBootstrapError(_ sessionId: String, error: String?) {
        var win = window(for: sessionId)
        win.bootstrapping = false
        win.bootstrapError = error
        windows[sessionId] = win
    }

    public func applyBootstrap(sessionId: String, entries: [Message], requestedLimit: Int) {
        touch(sessionId)
        merge(entries, into: sessionId)
        windows[sessionId] = TranscriptWindow(
            oldestLoadedId: Self.oldestId(nil, entries: entries),
            hasOlder: entries.count == requestedLimit,
            bootstrapped: true,
            bootstrapping: false,
            bootstrapError: nil,
            loadingOlder: false,
            olderError: nil,
            // A tail bootstrap is at the tail by definition — always the true newest, never a
            // reason to hold live appends back.
            newestLoadedId: Self.newestId(nil, entries: entries),
            hasNewer: false,
            loadingNewer: false,
            newerError: nil
        )
        // A fresh bootstrap re-establishes the window from scratch, so any ids held pending from
        // a PREVIOUS window's non-tail state describe a load that no longer exists.
        pendingNewerIds.removeValue(forKey: sessionId)
        evictOldSessions()
        reconcilePending(sessionId)
    }

    public func setLoadingOlder(_ sessionId: String, loading: Bool) {
        var win = window(for: sessionId)
        win.loadingOlder = loading
        // Mirrors the web: entering a load clears a stale error; leaving one (success or
        // failure) is handled by whichever of `prependOlder`/`setOlderError` runs next.
        if loading { win.olderError = nil }
        windows[sessionId] = win
    }

    public func prependOlder(sessionId: String, entries: [Message], requestedLimit: Int) {
        merge(entries, into: sessionId)
        var win = window(for: sessionId)
        win.oldestLoadedId = Self.oldestId(win.oldestLoadedId, entries: entries)
        win.hasOlder = entries.count == requestedLimit
        win.loadingOlder = false
        win.olderError = nil
        windows[sessionId] = win
    }

    public func setOlderError(_ sessionId: String, error: String?) {
        var win = window(for: sessionId)
        win.loadingOlder = false
        win.olderError = error
        windows[sessionId] = win
    }

    // MARK: - Merge

    /// Dedupe-and-sort-by-id merge shared by every path that adds messages to a session: SSE
    /// init/batch, the tail bootstrap, and an older-page load. All three become the same
    /// operation because the store holds one contiguous, ascending window per session — appends,
    /// prepends and overlaps (an SSE reconnect replaying rows already in the store) all just
    /// fall out of "merge by id, then sort".
    func merge(_ entries: [Message], into sessionId: String) {
        let existing = messages[sessionId] ?? []
        messages[sessionId] = Self.merged(existing, with: entries)
    }

    /// Folds newly-arrived (SSE) entries into the store: merged into the loaded window when it
    /// already reaches the tail, or held aside by id in `pendingNewerIds` when it does not —
    /// appending past a non-tail window's edge would open a gap between what is loaded and what
    /// just arrived. Only entries actually beyond `newestLoadedId` count as held aside; a
    /// redelivered id already inside the window (an SSE reconnect replaying a batch) is neither
    /// merged again (`merge` already dedupes) nor counted toward the pending set.
    ///
    /// `loadNewer`'s own catch-up step is what folds a held-aside id back in for real, once
    /// paging genuinely reaches it — see `TranscriptStore+Streaming.swift`'s callers.
    func foldLiveEntries(sessionId: String, entries: [Message]) {
        let win = window(for: sessionId)
        if win.hasNewer, let boundary = win.newestLoadedId {
            let beyond = entries.filter { $0.id > boundary }
            guard !beyond.isEmpty else { return }
            var set = pendingNewerIds[sessionId] ?? []
            for m in beyond { set.insert(m.id) }
            pendingNewerIds[sessionId] = set
            return
        }
        merge(entries, into: sessionId)
    }

    static func merged(_ existing: [Message], with entries: [Message]) -> [Message] {
        guard !entries.isEmpty else { return existing }
        let existingIds = Set(existing.map(\.id))
        let newEntries = entries.filter { !existingIds.contains($0.id) }
        guard !newEntries.isEmpty else { return existing }
        return (existing + newEntries).sorted { $0.id < $1.id }
    }

    static func oldestId(_ current: Int?, entries: [Message]) -> Int? {
        guard let batchMin = entries.map(\.id).min() else { return current }
        guard let current else { return batchMin }
        return Swift.min(current, batchMin)
    }

    static func newestId(_ current: Int?, entries: [Message]) -> Int? {
        guard let batchMax = entries.map(\.id).max() else { return current }
        guard let current else { return batchMax }
        return Swift.max(current, batchMax)
    }

    /// Whether each half of an `around_id` page came back full — the backend splits the request
    /// into `ceil(limit/2)` at-or-before `aroundId` and `floor(limit/2)` strictly after it, so a
    /// half short of its own request size is the same "no more this direction" signal
    /// `hasOlder`/`hasNewer` already read from a single-direction page, computed for both sides
    /// from one fetch instead of a second round trip to settle the other edge.
    static func halfFullFlags(_ entries: [Message], aroundId: Int, limit: Int) -> (hasOlder: Bool, hasNewer: Bool) {
        let beforeCount = entries.filter { $0.id <= aroundId }.count
        let afterCount = entries.filter { $0.id > aroundId }.count
        return (hasOlder: beforeCount == (limit + 1) / 2, hasNewer: afterCount == limit / 2)
    }

    /// Whether an `around_id` page overlaps or abuts the currently loaded window — `locate`'s own
    /// merge-or-replace decision (search-virtualization design: "the around page, and
    /// merge-or-replace"). True for anything that would leave the window a single contiguous
    /// range once folded in — the caller's cue to `mergeWindow` rather than `replaceWindow`,
    /// which would otherwise discard perfectly good context for a page that landed right next to
    /// it. An empty or never-loaded window overlaps nothing, since there is nothing to abut.
    public static func overlapsOrAbuts(_ window: TranscriptWindow, pageMin: Int, pageMax: Int) -> Bool {
        guard let oldest = window.oldestLoadedId, let newest = window.newestLoadedId else { return false }
        return pageMin <= newest + 1 && pageMax >= oldest - 1
    }

    // MARK: - Newer edge

    public func setLoadingNewer(_ sessionId: String, loading: Bool) {
        var win = window(for: sessionId)
        win.loadingNewer = loading
        if loading { win.newerError = nil }
        windows[sessionId] = win
    }

    public func setNewerError(_ sessionId: String, error: String?) {
        var win = window(for: sessionId)
        win.loadingNewer = false
        win.newerError = error
        windows[sessionId] = win
    }

    /// Appending below never moves anything a reader is looking at, unlike `prependOlder`'s older
    /// content — no scroll compensation is bound up in this action, the same way none is in the
    /// caller that requests this page.
    public func appendNewer(sessionId: String, entries: [Message], requestedLimit: Int) {
        merge(entries, into: sessionId)
        var win = window(for: sessionId)
        win.newestLoadedId = Self.newestId(win.newestLoadedId, entries: entries)
        win.hasNewer = entries.count == requestedLimit
        win.loadingNewer = false
        win.newerError = nil
        windows[sessionId] = win
    }

    public func getPendingNewerCount(_ sessionId: String) -> Int {
        pendingNewerIds[sessionId]?.count ?? 0
    }

    public func getPendingNewerHighWaterMark(_ sessionId: String) -> Int? {
        pendingNewerIds[sessionId]?.max()
    }

    public func clearPendingNewer(_ sessionId: String) {
        pendingNewerIds.removeValue(forKey: sessionId)
    }

    /// `locate`'s merge path: `entries` overlaps or abuts the already-loaded window, so they fold
    /// into one contiguous range rather than replacing it. Only the edge(s) this page actually
    /// reaches past get a new `hasOlder`/`hasNewer` reading — a side the page never touches is
    /// left exactly as it already was, the same one-direction-at-a-time discipline
    /// `prependOlder`/`appendNewer` each already keep.
    public func mergeWindow(sessionId: String, entries: [Message], aroundId: Int, limit: Int) {
        guard !entries.isEmpty else { return }
        let win = window(for: sessionId)
        merge(entries, into: sessionId)

        let ids = entries.map(\.id)
        let pageMin = ids.min()!
        let pageMax = ids.max()!
        let flags = Self.halfFullFlags(entries, aroundId: aroundId, limit: limit)
        let extendsOlder = win.oldestLoadedId == nil || pageMin < win.oldestLoadedId!
        let extendsNewer = win.newestLoadedId == nil || pageMax > win.newestLoadedId!

        var newWin = win
        newWin.oldestLoadedId = Self.oldestId(win.oldestLoadedId, entries: entries)
        newWin.newestLoadedId = Self.newestId(win.newestLoadedId, entries: entries)
        newWin.hasOlder = extendsOlder ? flags.hasOlder : win.hasOlder
        newWin.hasNewer = extendsNewer ? flags.hasNewer : win.hasNewer
        windows[sessionId] = newWin
    }

    /// `locate`'s replace path: `entries` sits nowhere near the already-loaded window, so it
    /// discards that window outright rather than producing a sparse, gapped list. A fresh window
    /// from scratch, same reasoning as `applyBootstrap`: anything held pending in
    /// `pendingNewerIds` describes a load that no longer exists.
    public func replaceWindow(sessionId: String, entries: [Message], aroundId: Int, limit: Int) {
        let sorted = entries.sorted { $0.id < $1.id }
        messages[sessionId] = sorted
        let flags = Self.halfFullFlags(entries, aroundId: aroundId, limit: limit)
        windows[sessionId] = TranscriptWindow(
            oldestLoadedId: Self.oldestId(nil, entries: entries),
            hasOlder: flags.hasOlder,
            bootstrapped: true,
            bootstrapping: false,
            bootstrapError: nil,
            loadingOlder: false,
            olderError: nil,
            newestLoadedId: Self.newestId(nil, entries: entries),
            hasNewer: flags.hasNewer,
            loadingNewer: false,
            newerError: nil
        )
        pendingNewerIds.removeValue(forKey: sessionId)
    }

    /// Jump-to-latest's own primitive: a REPLACE, not `applyBootstrap`'s merge — the window
    /// before this can be anywhere in the transcript, and merging a tail page into a distant one
    /// would produce exactly the sparse, gapped list the design rules out.
    public func resetToTail(sessionId: String, entries: [Message], requestedLimit: Int) {
        let sorted = entries.sorted { $0.id < $1.id }
        messages[sessionId] = sorted
        windows[sessionId] = TranscriptWindow(
            oldestLoadedId: Self.oldestId(nil, entries: entries),
            hasOlder: entries.count == requestedLimit,
            bootstrapped: true,
            bootstrapping: false,
            bootstrapError: nil,
            loadingOlder: false,
            olderError: nil,
            newestLoadedId: Self.newestId(nil, entries: entries),
            hasNewer: false,
            loadingNewer: false,
            newerError: nil
        )
        pendingNewerIds.removeValue(forKey: sessionId)
    }

    // MARK: - LRU

    func touch(_ sessionId: String) {
        sessionAccessOrder.removeAll { $0 == sessionId }
        sessionAccessOrder.append(sessionId)
    }

    /// Drops the oldest session's messages, window and send-tracking state once more than
    /// ``maxCachedSessions`` are loaded at once.
    ///
    /// "Send-tracking state" means every map keyed by session id that a revisit must not find
    /// stale — `pendingMessages` and `delivery` included. Missing either used to leave a session's
    /// last pending-send bubbles behind forever, so re-opening an evicted session before its next
    /// status event replayed them as phantom "queued" bubbles under a transcript that had already
    /// moved on.
    ///
    /// Unlike the web, there is no per-message row height to evict alongside: ``BlockHeightCache``
    /// is keyed by block content, width and measurement environment, never by message or session
    /// id, so a stale entry for a message nobody can reach again is simply never looked up again
    /// rather than needing to be found and deleted.
    func evictOldSessions() {
        while messages.count > Self.maxCachedSessions, !sessionAccessOrder.isEmpty {
            let oldest = sessionAccessOrder.removeFirst()
            messages.removeValue(forKey: oldest)
            windows.removeValue(forKey: oldest)
            sessionTokens.removeValue(forKey: oldest)
            pendingMessages.removeValue(forKey: oldest)
            delivery.removeValue(forKey: oldest)
            sseActivity.removeValue(forKey: oldest)
            isProcessing.removeValue(forKey: oldest)
            liveStatus.removeValue(forKey: oldest)
            pendingNewerIds.removeValue(forKey: oldest)
        }
    }

    // MARK: - Display filtering

    /// Drops assistant entries with no content, no tool calls and no thinking. Nothing else is
    /// filtered.
    ///
    /// A queued nudge's text used to reach the transcript twice; the parser now catches that at
    /// the source, because the two writes are not reliably adjacent, so a display-side dedupe
    /// check could never fully cover them anyway — and one that only sometimes fires would be
    /// worse than none, silently swallowing a message Freddy genuinely sent twice in a row.
    public static func displayMessages(_ messages: [Message]) -> [Message] {
        messages.filter { message in
            guard message.type == .assistant else { return true }
            let hasContent = !(message.content?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            let hasToolCalls = !(message.toolCalls?.isEmpty ?? true)
            let hasThinking = !(message.thinking?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            return hasContent || hasToolCalls || hasThinking
        }
    }
}
