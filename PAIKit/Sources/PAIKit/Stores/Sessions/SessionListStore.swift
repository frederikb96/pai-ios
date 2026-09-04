import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client. The conformance is declared
/// here, next to the protocol it satisfies, not inside `PaiApiClient.swift` itself.
public protocol SessionListApiClient: Sendable {
    func getSessions(
        since: String?, limit: Int?, cursor: String?, agent: String?, kind: SessionKind?, parent: String?, q: String?
    ) async throws -> SessionsPage
    func searchSessions(
        q: String, mode: SessionSearchMode?, agent: String?, limit: Int?
    ) async throws -> [SessionSearchResult]
    /// Only reached through `SessionListStore.deleteSession(id:)` — see its doc comment.
    func deleteSession(sessionId: String) async throws -> DeleteResponse
}

extension PaiApiClient: SessionListApiClient {}

/// One row as the view needs it — every field already resolved, so nothing about a row's
/// appearance is decided in `PAI/`. Deliberately does not carry a semantic `score`: the row
/// anatomy the web ports (`Sidebar.tsx`'s `SessionItem`) never shows one — the threshold slider
/// only ever decides *membership*, never what a row displays.
public struct SessionListRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let session: Session
    public let dotState: SessionDotState
    /// Whether Claude is actively mid-turn — the row shows a spinner in place of the dot rather
    /// than the dot itself. See `SessionListDomain.isWorking`.
    public let isWorking: Bool
    public let showsBlockedWarning: Bool
    public let showsAttentionWarning: Bool
    /// Already project-prefixed (`SessionListFormat.withProjectPrefix`) — the row never composes
    /// this itself.
    public let displayTitle: String
    /// `last_activity_at ?? created_at` — a raw ISO string, left for the view to parse and run
    /// through `SessionListFormat.timeBucket(for:)` with whatever `Date`/`DateFormatter` it has
    /// on hand. Kept as the source string rather than a pre-parsed `Date` so a row never silently
    /// loses the timestamp to a parse failure this store already tolerated elsewhere.
    public let lastActivityAt: String?
    public let sessionTokens: Int
    public let showsTokenCount: Bool
    /// What this session has running right now — `nil` when there is nothing to show, same as
    /// the source field. See `ActivityCounts`.
    public let activityCounts: ActivityCounts?
}

/// Why nothing is showing where a row list would be. `.loadingFirstResults` only applies to a
/// machine/query fetch that has not answered yet — the plain synced list has no equivalent
/// loading state, because it starts life already loaded via `loadInitialSessions()`.
public enum SessionListEmptyState: Sendable, Equatable {
    case none, loadingFirstResults, noMatchingSessions, noSessionsYet
}

/// Swift port of the session list's data flow: `pai-cloud/web/src/stores/session.ts` (the synced
/// list) and the filter/search routing inline in `Sidebar.tsx` (`useServerFilteredSessions`,
/// the debounce effect, the id-fragment short-circuit). Everything a session list VIEW needs is
/// `rows`, `emptyState`, `hasMoreRows`/`loadMoreRows`, and `searchError` — the rest of this type
/// is how those four stay correct.
///
/// **The three sources, and why there are three fetch paths below:**
/// - **A — the synced list** (`syncedSessions`): live, polled every 10s via `startPolling()`, the
///   only source that receives push-shaped updates at all — SSE-driven live updates arrive
///   outside this store's scope (the transcript/chat layer owns that connection) and are not
///   wired here; see the row 55 report for why they must land only on this list, never on B/C.
/// - **B — server browse** (`serverFilteredResults` when a machine chip is active and no text
///   query): paged, no live updates.
/// - **C — server search** (`serverFilteredResults` when a text query is active): ranked, **no
///   paging** — a ranked result set has no natural next page.
///
/// B and C going stale while active is a deliberate trade-off ported from the web, not a bug:
/// nothing pushes into them, and clearing back to "All" with no query is what restores the live
/// picture. Do not route live updates into them.
@MainActor
@Observable
public final class SessionListStore {
    static let sessionsPageSize = 100
    static let searchResultLimit = 100
    static let defaultSemanticThreshold = 0.0
    /// Long enough that ordinary typing produces one request, short enough that results still
    /// feel responsive. Applied only to raw typed text — a chip click, a mode toggle and the
    /// Enter key all bypass this, because each is a discrete choice, not a keystroke stream.
    public static let defaultTextDebounceNanos: UInt64 = 1_000_000_000
    private static let pollIntervalNanos: UInt64 = 10_000_000_000

    // MARK: Source A — the synced list

    public private(set) var syncedSessions: [Session] = []
    public private(set) var hasMoreSyncedSessions = false
    public private(set) var loadingMoreSyncedSessions = false
    private var syncedSessionsCursor: String?
    /// The client's own clock at the last successful sync — what the next incremental poll asks
    /// "what changed since". `nil` means the very first load has not happened yet.
    private(set) var lastSessionSync: String?
    /// Ids `ensureSessionLoaded` has already answered "no such session" for — a deleted one, or
    /// another account's. Kept so a view that keeps asking about the same missing id (a stale
    /// deep link, say) does not re-fire the same request on every read.
    public private(set) var unknownSessionIds: Set<String> = []

    // MARK: Filter / search UI state

    public private(set) var filterQueryText: String = ""
    private var debouncedQuery: String = ""
    public private(set) var machineFilter: String?
    public private(set) var semanticMode = false
    public var threshold: Double = SessionListStore.defaultSemanticThreshold

    // MARK: Sources B/C — server-filtered

    public private(set) var serverFilteredResults: [SessionSearchResult] = []
    private var serverFilteredCursor: String?
    public private(set) var serverFilteredHasMore = false
    public private(set) var serverFilteredLoading = false
    public private(set) var serverFilteredError: String?
    /// Only the response matching the current generation may ever write state — the guard
    /// against an older, slower request landing after a newer one.
    private var generation = 0
    /// The `(machine, query)` pair `serverFilteredResults` currently reflects — lets a refetch
    /// tell "the filter actually changed" from "the same filter re-fired" (the id-fragment fast
    /// path in `updateFilterText` always calls `refetchServerFiltered` even when neither the
    /// machine chip nor the effective query moved). Only the former should blank the array.
    private var resultsSourceKey: String?
    private var debounceTask: Task<Void, Never>?
    private var serverFilteredTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    private let api: SessionListApiClient
    private let debounceNanos: UInt64

    public init(
        api: SessionListApiClient, debounceNanos: UInt64 = SessionListStore.defaultTextDebounceNanos
    ) {
        self.api = api
        self.debounceNanos = debounceNanos
    }

    // MARK: - The view's surface

    /// Whether `query` reads as an id fragment — matched client-side only against what is already
    /// loaded, and never sent to the server (there is no id-search endpoint).
    public var isIdQuery: Bool { SessionFilterMatch.looksLikeIdFragment(filterQueryText) }

    /// Whether a machine chip or a committed text query is active — the switch between reading
    /// `syncedSessions` and reading `serverFilteredResults`.
    public var isServerFiltered: Bool { machineFilter != nil || effectiveTextQuery != nil }

    /// The rows a view renders, in order, with every per-row decision already made. Building this
    /// from `syncedSessions`/`serverFilteredResults` on every read rather than caching it keeps
    /// the source-of-truth arrays as the only state that can go stale — this is always derived.
    public var rows: [SessionListRow] {
        let base: [Session] =
            isServerFiltered
            ? thresholdFilteredServerResults.map(\.session)
            : syncedSessions
        // A subagent opened elsewhere lands in the same synced store so a chat view can find it
        // by id — it must never surface as a row of its own here.
        let withoutSubagents = base.filter { $0.kind != .subagent }
        let matched =
            isIdQuery
            ? withoutSubagents.filter { SessionFilterMatch.sessionIdMatches(filterQueryText, session: $0) }
            : withoutSubagents
        return matched.map(Self.makeRow)
    }

    /// `.loadingFirstResults` only, `.noMatchingSessions`/`.noSessionsYet` otherwise — driven by
    /// the raw typed text, not by whether a server request has actually gone out, matching the
    /// web exactly: the "No matching sessions" copy shows the instant there is anything typed,
    /// even mid-debounce.
    public var emptyState: SessionListEmptyState {
        guard rows.isEmpty else { return .none }
        if isLoadingFirstResults { return .loadingFirstResults }
        return filterQueryText.isEmpty ? .noSessionsYet : .noMatchingSessions
    }

    /// Only meaningful while a server-backed fetch is the active source — the synced list has
    /// nothing that can fail this way.
    public var searchError: String? { isServerFiltered ? serverFilteredError : nil }

    /// Suppressed for an id query: that is a client-side pass over what is already loaded, and
    /// there is nothing server-side left to page for it.
    public var hasMoreRows: Bool {
        guard !isIdQuery else { return false }
        return isServerFiltered ? serverFilteredHasMore : hasMoreSyncedSessions
    }

    public var isLoadingMoreRows: Bool { isServerFiltered ? serverFilteredLoading : loadingMoreSyncedSessions }

    public func loadMoreRows() async {
        if isServerFiltered { await loadMoreServerFiltered() } else { await loadMoreSyncedSessions() }
    }

    /// Looks a session up by id across every source this store has already loaded — the synced
    /// list first, then whatever machine-browse or search results are current. A session found
    /// only by search (source C) is not necessarily in the synced list (source A): it may be
    /// older than the pages loaded so far, and the synced list has no id-lookup endpoint of its
    /// own to fall back to.
    ///
    /// This is the cheap correct fix, not the thorough one: it only ever answers from what is
    /// already in memory, so a session found by search and then never touched by browse or the
    /// synced poll stays unresolved after `serverFilteredResults` is next overwritten (a fresh
    /// search, a cleared filter). `ensureSessionLoaded(id:)` below covers that case with a
    /// dedicated fetch-if-missing request.
    public func session(withId id: String) -> Session? {
        syncedSessions.first(where: { $0.id == id })
            ?? serverFilteredResults.first(where: { $0.session.id == id })?.session
    }

    /// Fetches a session by id when it is outside every page already loaded — opening a session
    /// by id from outside the loaded window (a deep link, a route restored after relaunch) would
    /// otherwise find nothing. Swift port of `session.ts`'s `ensureSessionLoaded`.
    ///
    /// `q: id, limit: 1` rather than a dedicated by-id endpoint: none exists (`GET /api/sessions`
    /// is the only session-list route), and its `q` matches a substring of `id` too — not only
    /// `title`/`initial_message` — so a full id finds exactly one row (`repository.py`'s
    /// `list_sessions_page` docstring). A no-op once the id is already loaded or already known
    /// missing; a failed request answers neither way, so a later call can still resolve it.
    public func ensureSessionLoaded(id: String) async {
        guard session(withId: id) == nil, !unknownSessionIds.contains(id) else { return }
        guard
            let page = try? await api.getSessions(
                since: nil, limit: 1, cursor: nil, agent: nil, kind: nil, parent: nil, q: id
            )
        else { return }
        if let found = page.sessions.first(where: { $0.id == id }) {
            upsertSession(found)
        } else {
            unknownSessionIds.insert(id)
        }
    }

    /// Insert-or-replace by id, re-sorting by activity — the same shape `fetchIncremental`'s merge
    /// uses, factored out because `ensureSessionLoaded` and `applyLiveStatus` both need exactly
    /// this on a single row rather than a whole page.
    private func upsertSession(_ session: Session) {
        if let index = syncedSessions.firstIndex(where: { $0.id == session.id }) {
            syncedSessions[index] = session
        } else {
            syncedSessions.append(session)
        }
        syncedSessions.sort(by: Self.byActivityDescending)
    }

    /// Routes a live SSE `status` event's session-level fields into this session's row, so the
    /// list reflects them while its transcript is open rather than waiting for the next poll —
    /// the event already carries them and nothing was reading them here. A no-op for a session
    /// this store has not loaded (a subagent, or one outside every loaded page): there is no row
    /// to update, and `ensureSessionLoaded` is the caller's tool for that case, not this one.
    public func applyLiveStatus(
        sessionId: String, state: SessionState?, blocker: Blocker?, working: Bool?,
        presenceState: SessionPresenceState?, activityCounts: ActivityCounts?
    ) {
        if let index = syncedSessions.firstIndex(where: { $0.id == sessionId }) {
            syncedSessions[index] = syncedSessions[index].withLiveStatus(
                state: state, blocker: blocker, working: working, presenceState: presenceState,
                activityCounts: activityCounts
            )
        }
        if let index = serverFilteredResults.firstIndex(where: { $0.session.id == sessionId }) {
            let updated = serverFilteredResults[index].session.withLiveStatus(
                state: state, blocker: blocker, working: working, presenceState: presenceState,
                activityCounts: activityCounts
            )
            serverFilteredResults[index] = SessionSearchResult(
                session: updated, score: serverFilteredResults[index].score
            )
        }
    }

    /// Replaces a row wholesale with the server's own answer — every mutation the actions menu
    /// performs (rename, close, idle timeout, move) returns the updated `Session`, and this is
    /// where that lands back in the list rather than waiting for the next poll to catch up.
    public func replaceSession(_ session: Session) {
        if let index = syncedSessions.firstIndex(where: { $0.id == session.id }) {
            syncedSessions[index] = session
        }
        if let index = serverFilteredResults.firstIndex(where: { $0.session.id == session.id }) {
            serverFilteredResults[index] = SessionSearchResult(
                session: session, score: serverFilteredResults[index].score
            )
        }
    }

    // MARK: - Filter bar actions

    /// Every keystroke in the filter field. An id fragment or an empty/whitespace-only string
    /// answers immediately (no debounce, no server round trip for the id case); anything else
    /// schedules a debounced commit, cancelling whatever commit was already pending.
    public func updateFilterText(_ text: String) {
        filterQueryText = text
        debounceTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if SessionFilterMatch.looksLikeIdFragment(text) || trimmed.isEmpty {
            debouncedQuery = ""
            refetchServerFiltered()
            return
        }
        debounceTask = Task { [weak self, debounceNanos] in
            try? await Task.sleep(nanoseconds: debounceNanos)
            guard let self, !Task.isCancelled else { return }
            self.debouncedQuery = trimmed
            self.refetchServerFiltered()
        }
    }

    /// The Enter key: answers now rather than waiting out the same debounce ordinary typing goes
    /// through. A no-op for an id query or empty text, matching the web's guard exactly.
    public func commitFilterTextNow() {
        let trimmed = filterQueryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isIdQuery, !trimmed.isEmpty else { return }
        debounceTask?.cancel()
        debouncedQuery = trimmed
        refetchServerFiltered()
    }

    /// A machine chip — `nil` for "All". A discrete choice, so it answers immediately.
    public func setMachineFilter(_ slug: String?) {
        machineFilter = slug
        refetchServerFiltered()
    }

    /// The semantic-mode toggle. A discrete choice, so it answers immediately too — including a
    /// currently-irrelevant refetch when no query is active, which is harmless and matches the
    /// web's own effect dependencies firing on this regardless.
    public func setSemanticMode(_ enabled: Bool) {
        semanticMode = enabled
        refetchServerFiltered()
    }

    /// The threshold slider. Never a fresh request — it re-filters the already-fetched top-N
    /// locally via `thresholdFilteredServerResults`. A band passed to the server instead is the
    /// 170x query-planner cliff this exists specifically to avoid.
    public func setThreshold(_ value: Double) {
        threshold = value
    }

    // MARK: - Source A: bootstrap, poll, page

    /// The first load — `GET /api/sessions?kind=conversation`, page one. Await this once before
    /// showing the list; `startPolling()` covers everything after.
    public func loadInitialSessions() async {
        guard
            let page = try? await api.getSessions(
                since: nil, limit: Self.sessionsPageSize, cursor: nil, agent: nil, kind: .conversation, parent: nil,
                q: nil
            )
        else { return }
        syncedSessions = page.sessions.sorted(by: Self.byActivityDescending)
        lastSessionSync = Self.isoNow()
        hasMoreSyncedSessions = page.nextCursor != nil
        syncedSessionsCursor = page.nextCursor
    }

    /// One incremental poll, or the first load if none has happened yet. Called on a 10s cadence
    /// by `startPolling()`; also callable directly (e.g. pull-to-refresh) without duplicating the
    /// bootstrap-vs-incremental branch.
    public func pollSyncedSessions() async {
        if let since = lastSessionSync {
            await fetchIncremental(since: since)
        } else {
            await loadInitialSessions()
        }
    }

    /// Starts the 10s recurring poll. Idempotent — a second call while one is already running
    /// does nothing. Sleeps before each poll, so callers that want the list populated for a first
    /// render should `await loadInitialSessions()` (or `pollSyncedSessions()`) once before this.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                await self.pollSyncedSessions()
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func loadMoreSyncedSessions() async {
        guard hasMoreSyncedSessions, !loadingMoreSyncedSessions, !syncedSessions.isEmpty,
            let cursor = syncedSessionsCursor
        else { return }
        loadingMoreSyncedSessions = true
        defer { loadingMoreSyncedSessions = false }
        guard
            let page = try? await api.getSessions(
                since: nil, limit: Self.sessionsPageSize, cursor: cursor, agent: nil, kind: .conversation, parent: nil,
                q: nil
            )
        else { return }
        // Every row in `page` sorts strictly after the cursor it was requested with, so
        // appending preserves order without a re-sort.
        let seen = Set(syncedSessions.map(\.id))
        syncedSessions.append(contentsOf: page.sessions.filter { !seen.contains($0.id) })
        hasMoreSyncedSessions = page.nextCursor != nil
        syncedSessionsCursor = page.nextCursor
    }

    /// Inserts a just-created session's optimistic row at the top of the synced list — the same
    /// unshift the web does in `createSession` before the next poll would otherwise pick it up.
    /// This store does not create sessions; whoever does (the create-session store) calls this
    /// once the create request answers.
    public func prependOptimisticSession(_ session: Session) {
        syncedSessions.insert(session, at: 0)
    }

    // MARK: - Delete

    /// Removes a row from the list at once and fires the real `DELETE` off the synchronous path —
    /// the row disappearing is what has to feel instant, not the network round trip. There is no
    /// hold and no undo: the delete is irreversible (it purges messages, the outbox and drafts,
    /// and cascades turns to phases to projects), and an undo that only worked because the delete
    /// had not happened yet would be worse than none. Swift port of `session.ts`'s `deleteSession`.
    public func deleteSession(id: String) {
        guard let session = session(withId: id) else { return }
        syncedSessions.removeAll { $0.id == id }
        serverFilteredResults.removeAll { $0.session.id == id }
        Task { [weak self, api] in
            do {
                _ = try await api.deleteSession(sessionId: id)
            } catch {
                // The request never reached the backend, so the session still exists there —
                // leaving it gone from the list would be a lie.
                self?.upsertSession(session)
            }
        }
    }

    // MARK: - Sources B/C: routing, debounce, generation + cancellation

    private var effectiveTextQuery: String? {
        guard !isIdQuery, !debouncedQuery.isEmpty else { return nil }
        return debouncedQuery
    }

    private var thresholdFilteredServerResults: [SessionSearchResult] {
        guard semanticMode, effectiveTextQuery != nil else { return serverFilteredResults }
        // Order stays exactly what the server sent (chronological, never score-ordered):
        // filtering a sorted array keeps it sorted.
        return serverFilteredResults.filter { ($0.score ?? 0) >= threshold }
    }

    private var isLoadingFirstResults: Bool {
        isServerFiltered && serverFilteredLoading && serverFilteredResults.isEmpty
    }

    /// Mirrors `useServerFilteredSessions`'s effect exactly, including what looks like a gap and
    /// is not one: when this is inactive, nothing is cancelled and nothing reset. A request that
    /// was in flight when the user cleared back to "All" keeps running to completion in the
    /// background; its answer is silently irrelevant because `isServerFiltered` is false, and if
    /// the user re-activates a filter afterward that path bumps `generation` again, which
    /// discards the stale answer whenever it eventually lands.
    private func refetchServerFiltered() {
        let machine = machineFilter
        let query = effectiveTextQuery
        guard machine != nil || query != nil else { return }

        serverFilteredTask?.cancel()
        generation += 1
        let myGeneration = generation
        let mode: SessionSearchMode = semanticMode ? .semantic : .fuzzy
        serverFilteredLoading = true
        serverFilteredError = nil
        // Only when the filter genuinely changed: the id-fragment fast path in
        // `updateFilterText` calls this on every keystroke even when neither the machine chip
        // nor the effective query moved, and blanking the array there would defeat its own
        // "matched client-side against what is already loaded" contract. When it did change,
        // this is what stops switching straight from one machine chip to another (or a fresh
        // search replacing the last one) from showing the previous filter's rows for as long as
        // the new fetch is in flight — `isLoadingFirstResults` requires
        // `serverFilteredResults.isEmpty`, which a stale-but-nonempty array defeats.
        let requestKey = Self.resultsSourceKey(machine: machine, query: query, mode: mode)
        if requestKey != resultsSourceKey {
            serverFilteredResults = []
        }

        serverFilteredTask = Task { [weak self] in
            guard let self else { return }
            if let query {
                do {
                    let results = try await self.api.searchSessions(
                        q: query, mode: mode, agent: machine, limit: Self.searchResultLimit
                    )
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    self.serverFilteredResults = results
                    self.serverFilteredCursor = nil
                    self.serverFilteredHasMore = false
                    self.resultsSourceKey = requestKey
                } catch {
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    if error is CancellationError { return }
                    self.serverFilteredError = (error as? PaiError)?.userMessage ?? "Search failed"
                }
            } else {
                do {
                    let page = try await self.api.getSessions(
                        since: nil, limit: Self.sessionsPageSize, cursor: nil, agent: machine, kind: .conversation,
                        parent: nil, q: nil
                    )
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    self.serverFilteredResults = page.sessions.map { SessionSearchResult(session: $0, score: nil) }
                    self.serverFilteredCursor = page.nextCursor
                    self.serverFilteredHasMore = page.nextCursor != nil
                    self.resultsSourceKey = requestKey
                } catch {
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    if error is CancellationError { return }
                    self.serverFilteredError = (error as? PaiError)?.userMessage ?? "Failed to load sessions"
                }
            }
            if self.generation == myGeneration { self.serverFilteredLoading = false }
        }
    }

    private static func resultsSourceKey(machine: String?, query: String?, mode: SessionSearchMode) -> String {
        "\(machine ?? "")\u{0}\(query ?? "")\u{0}\(mode.rawValue)"
    }

    /// Only for the browse source (B) — a ranked search result (C) has no natural next page.
    /// Unlike `refetchServerFiltered`, this never cancels a fresh query that starts while it is
    /// in flight — ported as-is; see `SessionListStore`'s report for the web's own gap here.
    public func loadMoreServerFiltered() async {
        guard machineFilter != nil, effectiveTextQuery == nil,
            let cursor = serverFilteredCursor, !serverFilteredLoading, !serverFilteredResults.isEmpty
        else { return }
        generation += 1
        let myGeneration = generation
        let machine = machineFilter
        serverFilteredLoading = true
        defer { if generation == myGeneration { serverFilteredLoading = false } }
        guard
            let page = try? await api.getSessions(
                since: nil, limit: Self.sessionsPageSize, cursor: cursor, agent: machine, kind: .conversation,
                parent: nil,
                q: nil
            )
        else { return }
        guard generation == myGeneration else { return }
        serverFilteredResults.append(contentsOf: page.sessions.map { SessionSearchResult(session: $0, score: nil) })
        serverFilteredCursor = page.nextCursor
        serverFilteredHasMore = page.nextCursor != nil
    }

    // MARK: - Private helpers

    private func fetchIncremental(since: String) async {
        var cursor = since
        var changed: [Session] = []
        while true {
            guard
                let page = try? await api.getSessions(
                    since: cursor, limit: Self.sessionsPageSize, cursor: nil, agent: nil, kind: nil, parent: nil, q: nil
                )
            else { return }
            if page.sessions.isEmpty { break }
            changed.append(contentsOf: page.sessions)
            // A full page whose rows all share one `updated_at` (all changed inside the same
            // clock tick) leaves `pageMax` equal to `cursor` — resending that same `since` would
            // fetch the identical page forever. Requiring forward progress bounds the loop; the
            // rare rows left beyond this page's size at that exact timestamp are picked up by the
            // next poll tick, same as `.hasOlder` paging catching up incrementally elsewhere.
            guard let pageMax = Self.maxUpdatedAt(page.sessions), pageMax > cursor else { break }
            cursor = pageMax
            if page.sessions.count < Self.sessionsPageSize { break }
        }

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: a duplicate id in
        // `syncedSessions` should never happen, but this merge runs on every poll tick and a
        // precondition crash here would be far worse than silently keeping the later duplicate.
        var byId = Dictionary(syncedSessions.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        for session in changed {
            if session.status == .deleted {
                byId.removeValue(forKey: session.id)
            } else {
                // The web guards this merge against `state`/`blocker`/`working` arriving
                // `undefined`, preserving whatever SSE already set. That payload shape never
                // actually reaches the client: `_session_to_dict`
                // (`pai-cloud/backend/src/pai_cloud/api.py`) always includes all three keys,
                // `null` or not — verified against the backend, not assumed from the comment.
                // So the incoming row always wins here, which is what the web's own guard does
                // in practice despite reading as doing more.
                byId[session.id] = session
            }
        }
        syncedSessions = byId.values.sorted(by: Self.byActivityDescending)
        lastSessionSync = cursor
    }

    private static func makeRow(_ session: Session) -> SessionListRow {
        SessionListRow(
            id: session.id,
            session: session,
            dotState: SessionListDomain.dotState(for: session),
            isWorking: SessionListDomain.isWorking(session),
            showsBlockedWarning: session.state == .blocked,
            showsAttentionWarning: session.state == .attention,
            displayTitle: SessionListFormat.withProjectPrefix(
                session.projectName, SessionListFormat.displayTitle(for: session)
            ),
            lastActivityAt: session.lastActivityAt ?? session.createdAt,
            sessionTokens: session.sessionTokens,
            showsTokenCount: session.sessionTokens > 0,
            activityCounts: session.activityCounts
        )
    }

    /// `updated_at` strings sort lexically — they are all the same ISO/UTC shape.
    private static func maxUpdatedAt(_ sessions: [Session]) -> String? {
        sessions.compactMap(\.updatedAt).max()
    }

    private static func byActivityDescending(_ a: Session, _ b: Session) -> Bool {
        (a.lastActivityAt ?? a.createdAt ?? "") > (b.lastActivityAt ?? b.createdAt ?? "")
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
