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
    /// The last-observed context-window figure, per session. Keyed rather than a single scalar
    /// so switching to a session that has not reported one yet can never show a different
    /// session's number — a reader falls back to the session's own persisted token count
    /// instead, never to this map.
    public internal(set) var sessionTokens: [String: Int] = [:]
    /// Keyed like `sessionTokens` and for the same reason: a scalar here showed the previous
    /// session's connection/spinner state on screen until the newly-switched-to session's first
    /// status event arrived and overwrote it.
    public internal(set) var sseConnected: [String: Bool] = [:]
    /// Keyed like `sseConnected` and for the same reason. Separate from it rather than folded in,
    /// since "a socket is open" and "content is actually flowing through it" are different
    /// questions — a connection can sit open with nothing arriving, which is exactly the state a
    /// bare `sseConnected` reads identically to a healthy one.
    public internal(set) var sseActivity: [String: StreamActivity] = [:]
    public internal(set) var isProcessing: [String: Bool] = [:]

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

    public func window(for sessionId: String) -> TranscriptWindow {
        windows[sessionId] ?? .empty
    }

    public func sseConnected(for sessionId: String) -> Bool {
        sseConnected[sessionId] ?? false
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
            olderError: nil
        )
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
            sseConnected.removeValue(forKey: oldest)
            isProcessing.removeValue(forKey: oldest)
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
