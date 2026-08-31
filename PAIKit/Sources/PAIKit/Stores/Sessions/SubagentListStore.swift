import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client. The conformance is declared
/// here, next to the protocol it satisfies.
public protocol SubagentListApiClient: Sendable {
    func getSessions(
        since: String?, limit: Int?, cursor: String?, agent: String?, kind: SessionKind?, parent: String?, q: String?
    ) async throws -> SessionsPage
}

extension PaiApiClient: SubagentListApiClient {}

/// One conversation's own subagents, newest activity first — Swift port of `SubagentPanel.tsx`'s
/// data flow.
///
/// Kept live by watching the parent session's own `activityCounts.agents`, not by any stream of
/// its own: this screen can be opened for a session that is not the active one, so a per-screen
/// SSE subscription is not a reliable signal here — the parent's activity count, kept current by
/// the ordinary app-wide session poll regardless of what is on screen, is. See `noteParentAgentsCount`.
@MainActor
@Observable
public final class SubagentListStore {
    static let pageSize = 100

    public let parentSessionId: String
    public private(set) var subagents: [Session] = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    private var nextCursor: String?
    /// The parent's `activityCounts.agents` last observed — set the first time
    /// `noteParentAgentsCount` is called so that first observation is a baseline, never itself
    /// read as a change worth a refetch.
    private var lastKnownParentAgentsCount: Int?

    private let api: SubagentListApiClient

    public init(parentSessionId: String, api: SubagentListApiClient) {
        self.parentSessionId = parentSessionId
        self.api = api
    }

    public var hasMore: Bool { nextCursor != nil }

    /// The first load, or a reload from the top — call when the screen appears.
    public func loadInitial() async {
        subagents = []
        nextCursor = nil
        errorMessage = nil
        await loadPage(cursor: nil)
    }

    public func loadMore() async {
        guard let cursor = nextCursor, !isLoading else { return }
        await loadPage(cursor: cursor)
    }

    private func loadPage(cursor: String?) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await api.getSessions(
                since: nil, limit: Self.pageSize, cursor: cursor, agent: nil, kind: .subagent,
                parent: parentSessionId, q: nil
            )
            // Defensive, matching `SessionListStore.rows`' own `kind != .subagent` filter on the
            // other side of this same split: the server is trusted to have already filtered by
            // `kind`/`parent`, but nothing here should render a row that turns out not to be one
            // of this parent's own subagents.
            let filtered = page.sessions.filter { $0.kind == .subagent && $0.parentSessionId == parentSessionId }
            subagents = cursor == nil ? filtered : subagents + filtered
            nextCursor = page.nextCursor
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load subagents"
        }
    }

    /// Called whenever the parent session's `activityCounts.agents` is observed to change — a
    /// subagent started, or one just finished, either way the cue to re-check the newest page.
    /// A no-op the first time it is called for this store, so observing the baseline is never
    /// itself mistaken for a change.
    ///
    /// Returns whether any row was newly prepended, so a view can anchor the reader's scroll
    /// position before re-reading this store's own state.
    @discardableResult
    public func noteParentAgentsCount(_ count: Int) async -> Bool {
        defer { lastKnownParentAgentsCount = count }
        guard let previous = lastKnownParentAgentsCount, previous != count else { return false }
        return await refreshTopPage()
    }

    /// Re-fetches only the newest page and folds it into what is already loaded: an existing row
    /// is replaced in place (same array position, so nothing shifts under a reader positioned
    /// further down), and only a genuinely new subagent is prepended. Never a wholesale replace —
    /// that would also discard every older page already scrolled into, and reset `hasMore`'s
    /// cursor.
    private func refreshTopPage() async -> Bool {
        guard
            let page = try? await api.getSessions(
                since: nil, limit: Self.pageSize, cursor: nil, agent: nil, kind: .subagent,
                parent: parentSessionId, q: nil
            )
        else { return false }
        let fresh = page.sessions.filter { $0.kind == .subagent && $0.parentSessionId == parentSessionId }
        let knownIds = Set(subagents.map(\.id))
        let brandNew = fresh.filter { !knownIds.contains($0.id) }
        let byId = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        let updated = subagents.map { byId[$0.id] ?? $0 }
        subagents = brandNew + updated
        return !brandNew.isEmpty
    }
}
