import Foundation
import Observation

/// The narrow slice of `PaiApiClient` the session actions menu needs.
public protocol SessionActionsApiClient: Sendable {
    func renameSession(sessionId: String, title: String) async throws -> Session
    func setTitleLocked(sessionId: String, locked: Bool) async throws -> Session
    func closeSession(sessionId: String) async throws -> CloseResponse
    func setIdleTimeout(sessionId: String, minutes: Int?) async throws -> Session
    func switchSessionProject(sessionId: String, projectId: String) async throws -> Session
    func switchSessionPhase(sessionId: String, phaseId: String) async throws -> Session
    func exportSession(sessionId: String, since: String?) async throws -> PaiExportResult
    func listMemoryProjects(query: String?, limit: Int?, offset: Int?) async throws -> MemoryProjectsPage
    func listMemoryPhases(projectId: String?, query: String?, limit: Int?, offset: Int?) async throws
        -> MemoryPhasesPage
}

extension PaiApiClient: SessionActionsApiClient {}

/// The export sheet's presets — `.all` omits `since` entirely and exports the whole session.
/// Swift port of `export.ts`'s `ExportPreset`/`sinceIsoForPreset`.
public enum ExportPreset: CaseIterable, Sendable, Equatable {
    case all, lastHour, last24Hours, last7Days

    public var label: String {
        switch self {
        case .all: return "Whole session"
        case .lastHour: return "Last hour"
        case .last24Hours: return "Last 24 hours"
        case .last7Days: return "Last 7 days"
        }
    }

    private var interval: TimeInterval? {
        switch self {
        case .all: return nil
        case .lastHour: return 3600
        case .last24Hours: return 86400
        case .last7Days: return 7 * 86400
        }
    }

    /// The `since` value to send — `nil` for `.all`, meaning omit the query param.
    public func sinceIso(now: Date = Date()) -> String? {
        guard let interval else { return nil }
        return ISO8601DateFormatter().string(from: now.addingTimeInterval(-interval))
    }
}

/// Every action the session actions menu offers, built fresh per presentation (the same lifetime
/// shape `CreateSessionStore` uses) and scoped to one session. Swift port of the mutating half of
/// `web/src/components/SessionActionsMenu.tsx` — delete's immediate-removal shape lives on
/// `SessionListStore` itself (`deleteSession(id:)`), since it is the list's row that disappears,
/// not a fact about one menu instance.
///
/// Every mutation here writes its result back into `sessionList` via `replaceSession(_:)` so the
/// row (and the open header, which reads through the same store) reflects it immediately rather
/// than waiting for the next poll.
@MainActor
@Observable
public final class SessionActionsStore {
    public let sessionId: String
    private let sessionList: SessionListStore
    private let api: SessionActionsApiClient

    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    public init(sessionId: String, sessionList: SessionListStore, api: SessionActionsApiClient) {
        self.sessionId = sessionId
        self.sessionList = sessionList
        self.api = api
    }

    public var session: Session? { sessionList.session(withId: sessionId) }

    @discardableResult
    public func rename(title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await run { try await self.api.renameSession(sessionId: self.sessionId, title: trimmed) }
    }

    /// The rename sheet's own checkbox is phrased "follow the phase name from the VM" — checked
    /// means unlocked (`!locked`), matching the web (`SessionActionsMenu.tsx`'s `saveRename`
    /// subview) exactly, so a caller reading this store's `session?.titleLocked` for that
    /// checkbox's initial state does not have to re-derive the inversion itself.
    @discardableResult
    public func setTitleLocked(_ locked: Bool) async -> Bool {
        await run { try await self.api.setTitleLocked(sessionId: self.sessionId, locked: locked) }
    }

    @discardableResult
    public func close() async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await api.closeSession(sessionId: sessionId)
            if result.status == .closeError {
                errorMessage = result.detail ?? "Could not close the session"
                return false
            }
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not close the session"
            return false
        }
    }

    @discardableResult
    public func setIdleTimeout(minutes: Int?) async -> Bool {
        await run { try await self.api.setIdleTimeout(sessionId: self.sessionId, minutes: minutes) }
    }

    @discardableResult
    public func switchProject(_ projectId: String) async -> Bool {
        await run { try await self.api.switchSessionProject(sessionId: self.sessionId, projectId: projectId) }
    }

    @discardableResult
    public func switchPhase(_ phaseId: String) async -> Bool {
        await run { try await self.api.switchSessionPhase(sessionId: self.sessionId, phaseId: phaseId) }
    }

    public func exportTranscript(since: String?) async -> PaiExportResult? {
        guard !isBusy else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await api.exportSession(sessionId: sessionId, since: since)
            errorMessage = nil
            return result
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Export failed"
            return nil
        }
    }

    /// Removes the row from the list and fires the real DELETE at once — see
    /// `SessionListStore.deleteSession`'s doc comment for why there is no hold and no undo.
    public func deleteNow() {
        sessionList.deleteSession(id: sessionId)
    }

    // MARK: - Move pickers

    public func makeProjectPicker() -> OffsetPagedListStore<MemoryProject> {
        OffsetPagedListStore { [api] query, limit, offset in
            let page = try await api.listMemoryProjects(
                query: query.isEmpty ? nil : query, limit: limit, offset: offset)
            return (items: page.projects, hasMore: offset + page.projects.count < page.total)
        }
    }

    /// `listMemoryPhases` reports no total — a full page is the honest "there may be more"
    /// heuristic, matching `PhaseSearchList.tsx`.
    public func makePhasePicker(projectId: String) -> OffsetPagedListStore<MemoryPhase> {
        OffsetPagedListStore { [api] query, limit, offset in
            let page = try await api.listMemoryPhases(
                projectId: projectId, query: query.isEmpty ? nil : query, limit: limit, offset: offset
            )
            return (items: page.phases, hasMore: page.phases.count == limit)
        }
    }

    // MARK: - Private

    private func run(_ request: @escaping () async throws -> Session) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        defer { isBusy = false }
        do {
            let updated = try await request()
            sessionList.replaceSession(updated)
            errorMessage = nil
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "That didn't go through"
            return false
        }
    }
}

/// Offset-paged, re-searchable list loading, shared by the move-to-project and move-to-phase
/// pickers — the smaller Swift port of `web/src/apps/memory/useOffsetList.ts`'s hook. Deliberately
/// not virtualized: these lists run to at most a few hundred single-line rows, the same reasoning
/// the web gives for skipping it there.
@MainActor
@Observable
public final class OffsetPagedListStore<Item: Sendable & Identifiable> {
    public static var pageSize: Int { 30 }

    public private(set) var items: [Item] = []
    public private(set) var hasMore = false
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?

    /// Setting this reloads from the top — a new search is a different list, not more of the old
    /// one, matching the web's effect on `query`.
    public var query: String = "" {
        didSet {
            guard oldValue != query else { return }
            Task { [weak self] in await self?.reload() }
        }
    }

    private let fetchPage:
        @Sendable (_ query: String, _ limit: Int, _ offset: Int) async throws -> (
            items: [Item], hasMore: Bool
        )
    /// Guards against a slower, superseded request (an earlier keystroke's) landing after a
    /// faster, more recent one — the web's hook has no such guard and can show this exact race;
    /// this is a genuine improvement over the port, not a diverging behaviour worth flagging.
    private var generation = 0

    public init(
        fetchPage: @escaping @Sendable (String, Int, Int) async throws -> (items: [Item], hasMore: Bool)
    ) {
        self.fetchPage = fetchPage
    }

    public func reload() async { await load(reset: true) }

    public func loadMore() async {
        guard hasMore, !isLoading, !items.isEmpty else { return }
        await load(reset: false)
    }

    private func load(reset: Bool) async {
        generation += 1
        let myGeneration = generation
        isLoading = true
        errorMessage = nil
        let offset = reset ? 0 : items.count
        do {
            let page = try await fetchPage(query, Self.pageSize, offset)
            guard generation == myGeneration else { return }
            items = reset ? page.items : items + page.items
            hasMore = page.hasMore
        } catch {
            guard generation == myGeneration else { return }
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the list"
        }
        if generation == myGeneration { isLoading = false }
    }
}
