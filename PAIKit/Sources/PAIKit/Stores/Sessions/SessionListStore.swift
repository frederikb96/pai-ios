import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client. The conformance is declared
/// here, next to the protocol it satisfies, not inside `PaiApiClient.swift` itself.
public protocol SessionListApiClient: Sendable {
    func getSessions(
        since: String?, limit: Int?, cursor: String?, agent: String?, kind: SessionKindFilter?, parent: String?,
        q: String?, window: TimeBounds?
    ) async throws -> SessionsPage
    func searchSessions(
        q: String, mode: SessionSearchMode?, agent: String?, limit: Int?, window: TimeBounds?
    ) async throws -> SessionSearchPage
    /// Only reached through `SessionListStore.deleteSession(id:)` — see its doc comment.
    func deleteSession(sessionId: String) async throws -> DeleteResponse
    /// Only reached through `SessionListStore.closeSession(id:onFailure:)` — see its doc comment.
    func closeSession(sessionId: String) async throws -> CloseResponse
    /// Only reached through `SessionListStore.togglePinned(id:)` — see its doc comment.
    func setPinned(sessionId: String, pinned: Bool) async throws -> Session
}

extension PaiApiClient: SessionListApiClient {}

/// One row as the view needs it — every field already resolved, so nothing about a row's
/// appearance is decided in `PAI/`. Deliberately does not carry a semantic `score`: no client
/// shows one. What it does carry is the tier the backend put a semantic hit in, and whether the
/// "Less likely" divider sits above this row.
public struct SessionListRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let session: Session
    public let dotState: SessionDotState
    /// Whether Claude is actively mid-turn — the row shows a spinner in place of the dot rather
    /// than the dot itself. See `SessionListDomain.isWorking`.
    public let isWorking: Bool
    public let showsBlockedWarning: Bool
    public let showsAttentionWarning: Bool
    /// The session is pinned (`pinned_at` set) — the row draws a pin beside its title, as the
    /// web's row does.
    public let showsPin: Bool
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
    /// `1` or `2` for a semantic hit, `nil` for every other row.
    public let tier: Int?
    /// The first tier-2 row of a tiered list: the view draws the divider above it.
    public let startsLessLikely: Bool
}

/// Why nothing is showing where a row list would be. `.loadingFirstResults` only applies to a
/// machine/query fetch that has not answered yet — the plain synced list has no equivalent
/// loading state, because it starts life already loaded via `loadInitialSessions()`.
public enum SessionListEmptyState: Sendable, Equatable {
    case none, loadingFirstResults, noMatchingSessions, noSessionsYet
    /// The text matches are empty and the semantic query has not answered yet.
    case searchingByMeaning
}

/// Swift port of the session list's data flow: `pai-cloud/web/src/stores/session.ts` (the synced
/// list) and the filter/search routing inline in `Sidebar.tsx` (`useServerFilteredSessions`,
/// the debounce effect, the id-fragment short-circuit). Everything a session list VIEW needs is
/// `rows`, `emptyState`, `hasMoreRows`/`loadMoreRows`, and `searchError` — the rest of this type
/// is how those four stay correct.
///
/// **The three sources, and why there are three fetch paths below:**
/// - **A — the synced list** (`syncedSessions`): live, the only source that receives push-shaped
///   updates at all. The account-wide notification stream wakes it (`requestSync()`), and a slow
///   poll via `startPolling()` is the backstop for a stream that is down. Status events from a
///   transcript stream are applied outside this store's scope; they must land only on this
///   list, never on B/C.
/// - **B — server browse** (`serverFilteredResults` when a machine chip is active and no text
///   query): paged, no live updates.
/// - **C — server search** (`serverFilteredResults` when a text query is active): a fuzzy search
///   is a filter over the list, newest activity first; a semantic one arrives tiered and is
///   shown in the order the backend sent. **No paging** — a result set has no natural next page.
///
/// A time window (`timeWindow`) narrows B and C and also turns the plain list into B: the synced
/// list holds only the pages loaded so far, and the window must reach older sessions.
///
/// B and C going stale while active is a deliberate trade-off ported from the web, not a bug:
/// nothing pushes into them, and clearing back to "All" with no query is what restores the live
/// picture. Do not route live updates into them.
@MainActor
@Observable
public final class SessionListStore {
    static let sessionsPageSize = 100
    /// The most the server will return for one search. A plain `List` realises its rows lazily, so
    /// asking for all of them costs one response, not 500 views.
    static let searchResultLimit = 500
    /// Applied only to raw typed text — a chip click, a mode toggle and the Enter key all bypass
    /// this, because each is a discrete choice, not a keystroke stream.
    ///
    /// This is the whole of what makes the session filter feel slow: the matcher itself
    /// (`search.py`) scores the entire corpus in memory and is not the bottleneck, so a full
    /// second of deliberate dead time before the request is what a reader experiences as lag.
    /// Sized so a burst of typing still collapses into a couple of requests rather than one per
    /// character.
    public static let defaultTextDebounceNanos: UInt64 = SearchTiming.debounceNanos
    /// The backstop cadence: the notification stream is what makes the list live.
    private static let pollIntervalNanos: UInt64 = 15_000_000_000

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
    /// The "Scheduled" chip — sessions the scheduler itself launched, exclusively, wherever they
    /// happen to run. Mutually exclusive with `machineFilter`, the same way "All" and a machine
    /// chip already are: filters the synced list (source A) rather than issuing a server query,
    /// since there is no server-side scheduled filter yet — every session already carries its own
    /// `taskId` once loaded.
    public private(set) var scheduledOnly = false
    public private(set) var semanticMode = false
    public private(set) var timeWindow: TimeWindow?

    // MARK: Sources B/C — server-filtered

    public private(set) var serverFilteredResults: [SessionSearchResult] = []
    private var serverFilteredCursor: String?
    public private(set) var serverFilteredHasMore = false
    public private(set) var serverFilteredLoading = false
    public private(set) var serverFilteredError: String?
    /// The shown search was cut to the limit asked for, so older matches exist that it does not
    /// list. Describes whichever list is on screen: the text matches, then the tiered result.
    public private(set) var searchTruncated = false
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
    private var semanticTask: Task<Void, Never>?
    private var semanticPhase: SemanticSearchPhase = .idle
    private var pollTask: Task<Void, Never>?
    private var syncInFlight = false
    private var syncRequestedAgain = false

    // MARK: Row positions

    /// Where a row sits in the list, kept apart from what it says: the order is by placement, and
    /// placements are renewed in one step after the list has been quiet (`SessionOrderSettler`).
    private struct Placement: Equatable {
        var pinnedAt: String?
        var activity: String
    }
    private var placements: [String: Placement] = [:]
    private let orderSettler: SessionOrderSettler
    /// Bumped by every settle: the one value a view animates the reorder against.
    public private(set) var orderRevision = 0

    private let api: SessionListApiClient
    private let debounceNanos: UInt64
    /// The clock a window is resolved against, so "Last 7 days" is measured from the moment each
    /// query runs.
    private let now: @Sendable () -> Date

    public init(
        api: SessionListApiClient, debounceNanos: UInt64 = SessionListStore.defaultTextDebounceNanos,
        now: @escaping @Sendable () -> Date = { Date() },
        orderTiming: SessionOrderSettler.Timing = .production
    ) {
        self.api = api
        self.debounceNanos = debounceNanos
        self.now = now
        self.orderSettler = SessionOrderSettler(timing: orderTiming)
        orderSettler.onSettle = { [weak self] in self?.settleOrder() }
    }

    // MARK: - The view's surface

    /// Whether `query` reads as an id fragment — matched client-side only against what is already
    /// loaded, and never sent to the server (there is no id-search endpoint).
    public var isIdQuery: Bool { SessionFilterMatch.looksLikeIdFragment(filterQueryText) }

    /// Whether a machine chip, a committed text query or a time window is active — the switch
    /// between reading `syncedSessions` and reading `serverFilteredResults`.
    public var isServerFiltered: Bool { machineFilter != nil || effectiveTextQuery != nil || timeWindow != nil }

    /// Whether the rows are a semantic result list: tiered, in the backend's order. Only once the
    /// tiered result has landed; before that the rows are the text matches.
    private var isTieredSearch: Bool { semanticStatus == .ready }

    /// Where the semantic query stands, `.idle` unless a semantic search is the active one. While
    /// it is `.searching` the rows are the text matches and a view shows them muted.
    public var semanticStatus: SemanticSearchPhase {
        semanticMode && effectiveTextQuery != nil ? semanticPhase : .idle
    }

    /// The rows a view renders, in order, with every per-row decision already made. Building this
    /// from `syncedSessions`/`serverFilteredResults` on every read rather than caching it keeps
    /// the source-of-truth arrays as the only state that can go stale — this is always derived.
    public var rows: [SessionListRow] {
        let source: [SessionSearchResult] =
            isServerFiltered
            ? serverFilteredResults : syncedSessions.map { SessionSearchResult(session: $0, score: nil, tier: nil) }
        // Exclusive, not an extra narrowing on top of the ordinary list — a scheduled session
        // shows under this toggle and nowhere else, whether or not a search is also active.
        // Matches the web's `Sidebar.tsx` (`scopedToView`).
        let scoped = source.filter { scheduledOnly ? $0.session.taskId != nil : $0.session.taskId == nil }
        // A subagent (opened from its parent's own subagents screen) or a supervisor (opened
        // from its worker's own menu) lands in this same synced store so a chat view can find it
        // by id — neither may ever surface as a row of its own here. A spoken Computer
        // conversation is not one of these: it belongs in the list exactly like any other
        // conversation, it simply cannot be typed into once opened.
        let withoutSubagents = scoped.filter { $0.session.kind != .subagent && $0.session.kind != .supervisor }
        let matched =
            isIdQuery
            ? withoutSubagents.filter { SessionFilterMatch.sessionIdMatches(filterQueryText, session: $0.session) }
            : withoutSubagents
        // A tiered list keeps the backend's order: pinning would lift a tier-2 row above the
        // divider that is meant to introduce it.
        let ordered = isTieredSearch ? matched : pinnedFirst(matched)
        let dividerIndex = isTieredSearch ? SearchTier.lessLikelyDividerIndex(in: ordered.map(\.tier)) : nil
        return ordered.enumerated().map { index, result in
            Self.makeRow(result.session, tier: result.tier, startsLessLikely: index == dividerIndex)
        }
    }

    /// `.loadingFirstResults` only, `.noMatchingSessions`/`.noSessionsYet` otherwise — driven by
    /// the raw typed text, not by whether a server request has actually gone out, matching the
    /// web exactly: the "No matching sessions" copy shows the instant there is anything typed,
    /// even mid-debounce.
    public var emptyState: SessionListEmptyState {
        guard rows.isEmpty else { return .none }
        if isLoadingFirstResults { return .loadingFirstResults }
        if semanticStatus == .searching { return .searchingByMeaning }
        return filterQueryText.isEmpty && timeWindow == nil ? .noSessionsYet : .noMatchingSessions
    }

    /// Only meaningful while a server-backed fetch is the active source — the synced list has
    /// nothing that can fail this way.
    /// The line to show under a search whose list was cut short, `nil` when there is none.
    public var truncationNotice: String? {
        isServerFiltered && effectiveTextQuery != nil && searchTruncated ? SearchTruncation.notice : nil
    }

    public var searchError: String? {
        guard isServerFiltered else { return nil }
        if let serverFilteredError { return serverFilteredError }
        if case let .failed(message) = semanticStatus { return message }
        return nil
    }

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
                since: nil, limit: 1, cursor: nil, agent: nil, kind: nil, parent: nil, q: id, window: nil
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
        place(session)
        sortSynced()
    }

    /// Puts the row a transfer produced on the target machine into the list, and — for a move,
    /// not a snapshot — marks the source as transferred so its menu stops offering the action
    /// before the next poll says so. Swift port of `session.ts`'s `transferSession` upsert.
    public func adoptTransferred(_ response: TransferResponse, from sourceId: String) {
        upsertSession(response.session)
        guard !response.snapshot else { return }
        if let index = syncedSessions.firstIndex(where: { $0.id == sourceId }) {
            syncedSessions[index].transferredToSessionId = response.session.id
        }
        if let index = serverFilteredResults.firstIndex(where: { $0.session.id == sourceId }) {
            var marked = serverFilteredResults[index].session
            marked.transferredToSessionId = response.session.id
            serverFilteredResults[index] = SessionSearchResult(
                session: marked, score: serverFilteredResults[index].score, tier: serverFilteredResults[index].tier)
        }
    }

    /// Routes a live SSE `status` event's session-level fields into this session's row, so the
    /// list reflects them while its transcript is open rather than waiting for the next poll —
    /// the event already carries them and nothing was reading them here. A no-op for a session
    /// this store has not loaded (a subagent, or one outside every loaded page): there is no row
    /// to update, and `ensureSessionLoaded` is the caller's tool for that case, not this one.
    ///
    /// `secretGrantable` travels the same path so the composer's grant entry reflects a session
    /// going live or closing without waiting for the next poll — see `Session.secretGrantable`.
    public func applyLiveStatus(
        sessionId: String, state: SessionState?, blocker: Blocker?, turnState: TurnState?,
        displayState: DisplayState?, activityCounts: ActivityCounts?, secretGrantable: Bool?,
        secretPrompt: SecretPrompt?, liveModel: String?, transfer: SessionMoved.Mark? = nil
    ) {
        if let index = syncedSessions.firstIndex(where: { $0.id == sessionId }) {
            syncedSessions[index] = syncedSessions[index].withLiveStatus(
                state: state, blocker: blocker, turnState: turnState, displayState: displayState,
                activityCounts: activityCounts, secretGrantable: secretGrantable, secretPrompt: secretPrompt,
                liveModel: liveModel, transfer: transfer
            )
        }
        if let index = serverFilteredResults.firstIndex(where: { $0.session.id == sessionId }) {
            let updated = serverFilteredResults[index].session.withLiveStatus(
                state: state, blocker: blocker, turnState: turnState, displayState: displayState,
                activityCounts: activityCounts, secretGrantable: secretGrantable, secretPrompt: secretPrompt,
                liveModel: liveModel, transfer: transfer
            )
            serverFilteredResults[index] = SessionSearchResult(
                session: updated, score: serverFilteredResults[index].score, tier: serverFilteredResults[index].tier
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
                session: session, score: serverFilteredResults[index].score, tier: serverFilteredResults[index].tier
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
        scheduledOnly = false
        refetchServerFiltered()
    }

    /// The "Scheduled" chip — exclusive with every machine chip, the same way they are exclusive
    /// with each other. Never issues a request: it re-filters the synced list already in memory.
    public func setScheduledOnly(_ enabled: Bool) {
        scheduledOnly = enabled
        guard enabled else { return }
        machineFilter = nil
        refetchServerFiltered()
    }

    /// The semantic-mode toggle. A discrete choice, so it answers immediately too — including a
    /// currently-irrelevant refetch when no query is active, which is harmless and matches the
    /// web's own effect dependencies firing on this regardless.
    public func setSemanticMode(_ enabled: Bool) {
        semanticMode = enabled
        refetchServerFiltered()
    }

    /// The time picker's choice, `nil` to clear it. A discrete choice, so it answers immediately.
    public func setTimeWindow(_ window: TimeWindow?) {
        timeWindow = window
        refetchServerFiltered()
    }

    // MARK: - Source A: bootstrap, poll, page

    /// The first load — `GET /api/sessions?kind=conversation`, page one. Await this once before
    /// showing the list; `startPolling()` covers everything after.
    public func loadInitialSessions() async {
        guard
            let page = try? await api.getSessions(
                since: nil, limit: Self.sessionsPageSize, cursor: nil, agent: nil, kind: .listed, parent: nil,
                q: nil, window: nil
            )
        else { return }
        placements = [:]
        page.sessions.forEach(place)
        syncedSessions = page.sessions
        sortSynced()
        // The server's own clock, not this device's: a phone running ahead would otherwise skip
        // every write between the server's now and its own.
        lastSessionSync = Self.maxUpdatedAt(page.sessions) ?? Self.isoNow()
        hasMoreSyncedSessions = page.nextCursor != nil
        syncedSessionsCursor = page.nextCursor
    }

    /// One incremental poll, or the first load if none has happened yet. Called on the backstop
    /// cadence by `startPolling()`, by the notification stream's wake and when the app returns
    /// to the foreground; also callable directly (e.g. pull-to-refresh) without duplicating the
    /// bootstrap-vs-incremental branch.
    ///
    /// A call made while a sync is running does not start a second one but asks for one more
    /// behind it: the running request may have left before the change that prompted the call,
    /// so dropping the call would leave that change unseen until the next wake or poll.
    public func pollSyncedSessions() async {
        if syncInFlight {
            syncRequestedAgain = true
            return
        }
        syncInFlight = true
        defer { syncInFlight = false }
        repeat {
            syncRequestedAgain = false
            await syncOnce()
        } while syncRequestedAgain
    }

    /// Fire-and-forget form of ``pollSyncedSessions()`` for a callback that cannot await.
    public func requestSync() {
        Task { await pollSyncedSessions() }
    }

    private func syncOnce() async {
        if let since = lastSessionSync {
            await fetchIncremental(since: since)
        } else {
            await loadInitialSessions()
        }
    }

    /// Starts the recurring backstop poll. Idempotent — a second call while one is already running
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
                since: nil, limit: Self.sessionsPageSize, cursor: cursor, agent: nil, kind: .listed, parent: nil,
                q: nil, window: nil
            )
        else { return }
        // Every row in `page` sorts strictly after the cursor it was requested with, so
        // appending preserves order without a re-sort.
        let seen = Set(syncedSessions.map(\.id))
        let appended = page.sessions.filter { !seen.contains($0.id) }
        appended.forEach(place)
        syncedSessions.append(contentsOf: appended)
        hasMoreSyncedSessions = page.nextCursor != nil
        syncedSessionsCursor = page.nextCursor
    }

    /// Puts a session a queued send has just created at the top of the list, and answers its id.
    ///
    /// The send belongs to ``OutboxStore``, not to this store: a create is an ordinary queued
    /// message that happens to name no session, so it survives a reload and cannot be sent twice.
    /// Swift port of `session.ts`'s `adoptCreatedSession`, called from the one place that knows a
    /// send has landed (``OutboxStore/installHandover(drafts:sessions:handoff:)``).
    ///
    /// `nil` for anything that is not a create that reached the server. A row the poll has
    /// already brought in is left exactly as it is while the id is still answered — a caller's
    /// navigation must not depend on which of the two arrived first.
    @discardableResult
    public func adoptCreatedSession(_ entry: OutboxEntry) -> String? {
        guard case .newSession = entry.target, let result = entry.result else { return nil }
        guard session(withId: result.sessionId) == nil else { return result.sessionId }
        let now = ISO8601DateFormatter().string(from: Date())
        let created = Session(
            id: result.sessionId,
            sessionType: entry.target.sessionType ?? "default",
            model: entry.target.model,
            thinking: entry.target.thinking,
            status: .pending,
            state: .starting,
            blocker: nil,
            displayState: .starting,
            title: nil,
            titleLocked: nil,
            initialMessage: entry.text,
            sessionTokens: 0,
            claudeSessionId: nil,
            idleTimeoutMinutes: nil,
            effectiveIdleTimeoutMinutes: nil,
            cseId: nil,
            createdAt: now,
            // No version of its own, deliberately: this row is a guess, and the server's
            // first copy of it has to replace it whatever its own `updated_at` says. A
            // client-minted one is compared against the server's by `isStaleVersion`, so a
            // phone clock even slightly ahead makes the real row read as stale and the guess
            // outlive it.
            updatedAt: nil,
            lastActivityAt: now,
            workingDir: entry.target.workingDir,
            agent: entry.target.agent,
            kind: .conversation,
            parentSessionId: nil,
            subagentName: nil,
            subagentType: nil,
            subagentDescription: nil,
            // Optimistic and technically premature — ported as-is from the web; the real
            // value arrives on the next poll.
            remoteControl: true,
            discovered: nil,
            projectId: nil,
            phaseId: nil,
            projectName: nil
        )
        place(created)
        syncedSessions.insert(created, at: 0)
        return result.sessionId
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

    // MARK: - Close

    /// Fires the close and returns at once — the round trip relays to the agent to actually kill
    /// the tmux process, not merely a database write, so it can take several seconds, and a caller
    /// awaiting it before dismissing looks hung for that whole window. Same fire-and-forget shape
    /// as `deleteSession`, minus the optimistic removal — a session cannot be shown "closing", only closed or
    /// not, so there is nothing to roll back on failure. `onFailure` is how a caller several
    /// seconds and possibly a dismissed screen away still hears about a failure.
    ///
    /// The row's `state` only flips to `.closed` once the backend actually confirms it, matching
    /// the web's own `closeSession` (`session.ts`) — a failed request therefore leaves the row
    /// exactly as it was, never reading as closed when it is not.
    public func closeSession(id: String, onFailure: (@Sendable @MainActor (String) -> Void)? = nil) {
        Task { [weak self, api] in
            do {
                let result = try await api.closeSession(sessionId: id)
                guard let self else { return }
                switch result.status {
                case .closed, .alreadyClosed:
                    // Mirrors the backend's own mutation (`close_session` sets exactly `state`
                    // and `blocker`) rather than `applyLiveStatus`'s SSE-shaped update, which
                    // would blank `turnState`/`displayState`/`activityCounts`/`secretGrantable`
                    // this response says nothing about.
                    if let session = self.session(withId: id) {
                        self.replaceSession(
                            session.withLiveStatus(
                                // `displayState` moves with `state` or the row keeps its spinner
                                // until the next poll — up to `pollIntervalNanos` of a session
                                // the reader just closed still showing "Working…". Optimistic
                                // but not a guess: the backend's own derivation returns `closed`
                                // for a closed session, unconditionally.
                                state: .closed, blocker: nil, turnState: session.turnState,
                                displayState: .closed, activityCounts: session.activityCounts,
                                secretGrantable: session.secretGrantable, secretPrompt: session.secretPrompt,
                                liveModel: session.liveModel
                            )
                        )
                    }
                case .closeError:
                    onFailure?(result.detail ?? "Could not close the session")
                }
            } catch {
                onFailure?((error as? PaiError)?.userMessage ?? "Could not close the session")
            }
        }
    }

    // MARK: - Pin

    /// Flips a session's pin, reordering the list at once — the toggle is what has to feel
    /// instant, not the round trip. Same fire-and-forget-with-rollback shape as `deleteSession`,
    /// the only other mutation here that applies locally before the server confirms it: a
    /// re-pin keeps its original `pinned_at` server-side, so this placeholder value is only ever
    /// shown until the response lands and replaces it with the real one.
    public func togglePinned(id: String) {
        guard let session = session(withId: id) else { return }
        let pinning = session.pinnedAt == nil
        replaceSession(session.withPinnedAt(pinning ? Self.isoNow() : nil))
        settleOrderNow()
        Task { [weak self, api] in
            do {
                let updated = try await api.setPinned(sessionId: id, pinned: pinning)
                self?.replaceSession(updated)
            } catch {
                // The request never reached the backend — put the row back exactly as it was.
                self?.replaceSession(session)
            }
            self?.settleOrderNow()
        }
    }

    // MARK: - Sources B/C: routing, debounce, generation + cancellation

    private var effectiveTextQuery: String? {
        guard !isIdQuery, !debouncedQuery.isEmpty else { return nil }
        return debouncedQuery
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
        let window = timeWindow
        guard machine != nil || query != nil || window != nil else { return }
        let bounds = window?.bounds(now: now())

        serverFilteredTask?.cancel()
        semanticTask?.cancel()
        generation += 1
        let myGeneration = generation
        let mode: SessionSearchMode = semanticMode ? .semantic : .fuzzy
        semanticPhase = semanticMode && query != nil ? .searching : .idle
        serverFilteredLoading = true
        serverFilteredError = nil
        searchTruncated = false
        // Only when the filter genuinely changed: the id-fragment fast path in
        // `updateFilterText` calls this on every keystroke even when neither the machine chip
        // nor the effective query moved, and blanking the array there would defeat its own
        // "matched client-side against what is already loaded" contract. When it did change,
        // this is what stops switching straight from one machine chip to another (or a fresh
        // search replacing the last one) from showing the previous filter's rows for as long as
        // the new fetch is in flight — `isLoadingFirstResults` requires
        // `serverFilteredResults.isEmpty`, which a stale-but-nonempty array defeats.
        let requestKey = Self.resultsSourceKey(machine: machine, query: query, mode: mode, window: window)
        if requestKey != resultsSourceKey {
            serverFilteredResults = []
        }

        serverFilteredTask = Task { [weak self] in
            guard let self else { return }
            if let query {
                do {
                    // Always the text match, also in semantic mode: it is what shows until the
                    // tiered result lands.
                    let page = try await self.api.searchSessions(
                        q: query, mode: .fuzzy, agent: machine, limit: Self.searchResultLimit, window: bounds
                    )
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    // The tiered result may have landed first; the text matches never replace it.
                    // A fuzzy hit has no tier: the result is the list narrowed, newest activity
                    // first, whatever order the matcher ranked it in.
                    if self.semanticPhase != .ready {
                        self.serverFilteredResults = page.results.sorted {
                            Self.byActivityDescending($0.session, $1.session)
                        }
                        self.searchTruncated = page.truncated
                        self.serverFilteredCursor = nil
                        self.serverFilteredHasMore = false
                        self.resultsSourceKey = requestKey
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    if error is CancellationError { return }
                    self.serverFilteredError = (error as? PaiError)?.userMessage ?? "Search failed"
                }
            } else {
                do {
                    let page = try await self.api.getSessions(
                        since: nil, limit: Self.sessionsPageSize, cursor: nil, agent: machine, kind: .listed,
                        parent: nil, q: nil, window: bounds
                    )
                    guard !Task.isCancelled, self.generation == myGeneration else { return }
                    self.serverFilteredResults = page.sessions.map {
                        SessionSearchResult(session: $0, score: nil, tier: nil)
                    }
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

        guard semanticMode, let query else { return }
        semanticTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.api.searchSessions(
                    q: query, mode: .semantic, agent: machine, limit: Self.searchResultLimit, window: bounds
                )
                guard !Task.isCancelled, self.generation == myGeneration else { return }
                self.serverFilteredResults = page.results
                self.searchTruncated = page.truncated
                self.serverFilteredCursor = nil
                self.serverFilteredHasMore = false
                self.resultsSourceKey = requestKey
                self.semanticPhase = .ready
            } catch {
                guard !Task.isCancelled, self.generation == myGeneration else { return }
                if error is CancellationError { return }
                self.semanticPhase = SemanticSearchPhase.outcome(of: error)
            }
        }
    }

    private static func resultsSourceKey(
        machine: String?, query: String?, mode: SessionSearchMode, window: TimeWindow?
    ) -> String {
        "\(machine ?? "")\u{0}\(query ?? "")\u{0}\(mode.rawValue)\u{0}\(String(describing: window))"
    }

    /// Only for the browse source (B) — a ranked search result (C) has no natural next page.
    /// Unlike `refetchServerFiltered`, this never cancels a fresh query that starts while it is
    /// in flight — ported as-is; see `SessionListStore`'s report for the web's own gap here.
    public func loadMoreServerFiltered() async {
        guard machineFilter != nil || timeWindow != nil, effectiveTextQuery == nil,
            let cursor = serverFilteredCursor, !serverFilteredLoading, !serverFilteredResults.isEmpty
        else { return }
        generation += 1
        let myGeneration = generation
        let machine = machineFilter
        let bounds = timeWindow?.bounds(now: now())
        serverFilteredLoading = true
        defer { if generation == myGeneration { serverFilteredLoading = false } }
        guard
            let page = try? await api.getSessions(
                since: nil, limit: Self.sessionsPageSize, cursor: cursor, agent: machine, kind: .listed,
                parent: nil,
                q: nil, window: bounds
            )
        else { return }
        guard generation == myGeneration else { return }
        serverFilteredResults.append(
            contentsOf: page.sessions.map { SessionSearchResult(session: $0, score: nil, tier: nil) })
        serverFilteredCursor = page.nextCursor
        serverFilteredHasMore = page.nextCursor != nil
    }

    // MARK: - Private helpers

    private func fetchIncremental(since: String) async {
        // A row's `updated_at` is stamped when its write starts, not when it commits, so a row
        // can become visible with a stamp older than a cursor that already moved past it. The
        // first request of a poll therefore starts `syncOverlapSeconds` before the cursor; rows
        // it returns a second time are dropped as stale versions in the merge below, and the
        // cursor never moves back.
        var cursor = since
        var from = Self.syncStart(since)
        var changed: [Session] = []
        while true {
            guard
                let page = try? await api.getSessions(
                    since: from, limit: Self.sessionsPageSize, cursor: nil, agent: nil, kind: nil, parent: nil,
                    q: nil,
                    window: nil
                )
            else { return }
            if page.sessions.isEmpty { break }
            changed.append(contentsOf: page.sessions)
            // A full page whose rows all share one `updated_at` (all changed inside the same
            // clock tick) leaves `pageMax` equal to `cursor` — resending that same `since` would
            // fetch the identical page forever. Requiring forward progress bounds the loop; the
            // rare rows left beyond this page's size at that exact timestamp are picked up by the
            // next poll tick, same as `.hasOlder` paging catching up incrementally elsewhere.
            guard let pageMax = Self.maxUpdatedAt(page.sessions) else { break }
            if Self.isLater(pageMax, than: cursor) { cursor = pageMax }
            guard Self.isLater(pageMax, than: from), page.sessions.count == Self.sessionsPageSize else { break }
            from = pageMax
        }

        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: a duplicate id in
        // `syncedSessions` should never happen, but this merge runs on every poll tick and a
        // precondition crash here would be far worse than silently keeping the later duplicate.
        var byId = Dictionary(syncedSessions.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        var reorders = false
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
                //
                // A poll already in flight when something newer landed (a status push, a resume's
                // own answer) answers with the row's old version; applying it rolls the screen
                // back. Only a strictly newer `updated_at` replaces a held row.
                if let held = byId[session.id], Self.isStaleVersion(held: held, incoming: session) { continue }
                // A row new to the list waits at the bottom for the next settle, so it does not
                // push the rows above it down; a known row keeps its place however its content
                // moved.
                if byId[session.id] == nil { placements[session.id] = Placement(pinnedAt: nil, activity: "") }
                byId[session.id] = session
                if isMisplaced(session) { reorders = true }
            }
        }
        syncedSessions = Array(byId.values)
        sortSynced()
        if reorders { orderSettler.markUnsettled() }
        lastSessionSync = cursor
    }

    /// Pinned rows first, in the order they were pinned (oldest pin on top), then every other row
    /// in whatever order it already had. Applied only here, at the view's own read, rather than to
    /// `syncedSessions` itself: that array's order is what the merge/staleness logic above keys
    /// on, and this grouping is a pure presentation concern layered on top of it. `pinned_at` is
    /// compared as its ISO-8601 text, which orders correctly for the server's own uniform format.
    private func pinnedFirst(_ results: [SessionSearchResult]) -> [SessionSearchResult] {
        let pinned = results.filter { placement(of: $0.session).pinnedAt != nil }.sorted {
            (placement(of: $0.session).pinnedAt ?? "") < (placement(of: $1.session).pinnedAt ?? "")
        }
        return pinned + results.filter { placement(of: $0.session).pinnedAt == nil }
    }

    // MARK: - Row positions

    private func placement(of session: Session) -> Placement {
        placements[session.id] ?? Placement(pinnedAt: session.pinnedAt, activity: Self.activity(of: session))
    }

    private func place(_ session: Session) {
        placements[session.id] = Placement(pinnedAt: session.pinnedAt, activity: Self.activity(of: session))
    }

    /// Whether a row's live values differ from where it is placed.
    private func isMisplaced(_ session: Session) -> Bool {
        guard let placed = placements[session.id] else { return false }
        return placed != Placement(pinnedAt: session.pinnedAt, activity: Self.activity(of: session))
    }

    /// Newest placed activity first; the pin grouping is applied where the rows are read.
    private func sortSynced() {
        syncedSessions.sort { placement(of: $0).activity > placement(of: $1).activity }
    }

    /// One step: every row takes the position it currently says it has.
    private func settleOrder() {
        syncedSessions.forEach(place)
        sortSynced()
        orderRevision += 1
    }

    /// The reader acted (a pin, a message they sent): the list reorders now, pending changes
    /// included.
    private func settleOrderNow() {
        orderSettler.settleNow()
    }

    // MARK: - Holding the order while the list is in use

    /// A finger is on the list; the order is held for as long as it stays there.
    public func setListTouching(_ touching: Bool) { orderSettler.setTouching(touching) }

    /// The list is moving under the reader.
    public func noteListInteraction() { orderSettler.noteInteraction() }

    /// Whether the list is scrolled away from its top; the rows in view stay where they are.
    public func setListAwayFromTop(_ away: Bool) { orderSettler.setAwayFromTop(away) }

    /// The list left the screen: nothing is being looked at, so the order catches up.
    public func releaseListHold() { orderSettler.releaseHold() }

    /// The reader sent a message to this session: its row moves to the top at once.
    public func noteOwnSend(sessionId: String) {
        guard let index = syncedSessions.firstIndex(where: { $0.id == sessionId }) else { return }
        syncedSessions[index] = syncedSessions[index].withLastActivityAt(Self.isoNow())
        settleOrderNow()
    }

    private static func makeRow(_ session: Session, tier: Int?, startsLessLikely: Bool) -> SessionListRow {
        SessionListRow(
            id: session.id,
            session: session,
            dotState: SessionListDomain.dotState(for: session),
            isWorking: SessionListDomain.isWorking(session),
            showsBlockedWarning: session.state == .blocked,
            showsAttentionWarning: session.state == .attention,
            showsPin: session.pinnedAt != nil,
            displayTitle: SessionListFormat.withProjectPrefix(
                session.projectName, SessionListFormat.displayTitle(for: session)
            ),
            lastActivityAt: session.lastActivityAt ?? session.createdAt,
            sessionTokens: session.sessionTokens,
            showsTokenCount: session.sessionTokens > 0,
            activityCounts: session.activityCounts,
            tier: tier,
            startsLessLikely: startsLessLikely
        )
    }

    /// Whether `incoming` is a version of the row no newer than `held`. Compared as integer
    /// microseconds, not lexically: Python's `isoformat()` drops the fraction when it is zero, and
    /// a millisecond-precision `Date` would read two writes inside one millisecond as one version.
    /// Mirrors the web client's `isStaleVersion` (`web/src/stores/session.ts` in pai-cloud).
    static func isStaleVersion(held: Session, incoming: Session) -> Bool {
        guard
            let heldText = held.updatedAt, let incomingText = incoming.updatedAt,
            let heldMicros = versionMicros(heldText), let incomingMicros = versionMicros(incomingText)
        else { return false }
        return incomingMicros <= heldMicros
    }

    static func versionMicros(_ text: String) -> Int64? {
        guard let date = IsoTimestamp.date(from: text) else { return nil }
        var subMillisecond: Int64 = 0
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
            let padded = (String(digits) + "000000").prefix(6)
            subMillisecond = Int64(padded.suffix(3)) ?? 0
        }
        return Int64((date.timeIntervalSince1970 * 1000).rounded()) * 1000 + subMillisecond
    }

    /// `updated_at` strings sort lexically — they are all the same ISO/UTC shape.
    private static func maxUpdatedAt(_ sessions: [Session]) -> String? {
        sessions.compactMap(\.updatedAt).max()
    }

    private static func byActivityDescending(_ a: Session, _ b: Session) -> Bool {
        activity(of: a) > activity(of: b)
    }

    private static func activity(of session: Session) -> String {
        session.lastActivityAt ?? session.createdAt ?? ""
    }

    /// How far before the sync cursor a poll starts.
    static let syncOverlapSeconds: TimeInterval = 3

    /// Where a poll holding `cursor` asks from.
    static func syncStart(_ cursor: String) -> String {
        guard let date = IsoTimestamp.date(from: cursor) else { return cursor }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date.addingTimeInterval(-syncOverlapSeconds))
    }

    /// Whether `a` is a later instant than `b`, compared as microseconds because the two strings
    /// can differ in shape (`Z` against `+00:00`, with or without a fraction).
    private static func isLater(_ a: String, than b: String) -> Bool {
        guard let left = versionMicros(a), let right = versionMicros(b) else { return a > b }
        return left > right
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
