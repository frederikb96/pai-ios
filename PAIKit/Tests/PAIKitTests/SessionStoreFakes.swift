import Foundation
@testable import PAIKit

/// Fakes shared by the `SessionStore*` test files — one `actor` each per protocol these stores
/// depend on, so a test can both script canned responses and read back exactly which calls were
/// made, without touching the network stack `PaiApiClientTests` already covers.

// MARK: - SessionListApiClient

actor FakeSessionListApi: SessionListApiClient {
    struct GetSessionsCall: Equatable {
        let since: String?
        let limit: Int?
        let cursor: String?
        let agent: String?
        let kind: SessionKind?
        let q: String?
    }

    struct SearchCall: Equatable {
        let q: String
        let mode: SessionSearchMode?
        let agent: String?
        let limit: Int?
    }

    private(set) var getSessionsCalls: [GetSessionsCall] = []
    private(set) var searchCalls: [SearchCall] = []
    private(set) var deleteSessionCalls: [String] = []
    var deleteSessionResult: Result<DeleteResponse, PaiError> = .success(DeleteResponse(status: .deleted))

    /// FIFO per matcher: `getSessions` pulls the next queued page whose predicate matches `since`
    /// being non-nil or nil, letting incremental-poll pages and cold-load/browse pages be scripted
    /// independently without the test having to thread call counts through by hand.
    var getSessionsResult: (@Sendable (GetSessionsCall) async -> Result<SessionsPage, PaiError>)?
    var searchResult: (@Sendable (SearchCall) async -> Result<[SessionSearchResult], PaiError>)?

    /// Lets a test suspend a specific call (keyed by whatever it chooses — usually `q` or
    /// `agent`) until it explicitly releases it, to script response ORDER independently of call
    /// order — the shape a race test needs.
    let gate = CallGate()

    func getSessions(
        since: String?, limit: Int?, cursor: String?, agent: String?, kind: SessionKind?, parent: String?, q: String?
    ) async throws -> SessionsPage {
        let call = GetSessionsCall(since: since, limit: limit, cursor: cursor, agent: agent, kind: kind, q: q)
        getSessionsCalls.append(call)
        await gate.wait(for: Self.gateKey(call))
        guard let getSessionsResult else { return SessionsPage(sessions: [], nextCursor: nil) }
        switch await getSessionsResult(call) {
        case let .success(page): return page
        case let .failure(error): throw error
        }
    }

    func searchSessions(q: String, mode: SessionSearchMode?, agent: String?, limit: Int?) async throws
        -> [SessionSearchResult]
    {
        let call = SearchCall(q: q, mode: mode, agent: agent, limit: limit)
        searchCalls.append(call)
        await gate.wait(for: "search:\(q)")
        guard let searchResult else { return [] }
        switch await searchResult(call) {
        case let .success(results): return results
        case let .failure(error): throw error
        }
    }

    func deleteSession(sessionId: String) async throws -> DeleteResponse {
        deleteSessionCalls.append(sessionId)
        // Recorded before the gate, not after, so a test can observe the request having started
        // and hold it there — the shape an undo-races-the-in-flight-DELETE test needs.
        await gate.wait(for: "delete:\(sessionId)")
        switch deleteSessionResult {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }

    /// The gate key a `getSessions` call waits on — `since` calls key on `since` itself (each
    /// poll tick is distinguishable), everything else keys on `agent` (browse/cursor calls for
    /// one machine share a gate, matching that only one such fetch is ever in flight per machine
    /// filter in these tests).
    private static func gateKey(_ call: GetSessionsCall) -> String {
        if let since = call.since { return "since:\(since)" }
        if let cursor = call.cursor { return "cursor:\(cursor)" }
        return "browse:\(call.agent ?? "nil")"
    }
}

/// Gates a piece of async work by name, so a race test can control resolution ORDER independently
/// of call order. Opt-in: an un-armed key never blocks, so every test that does not care about
/// timing can ignore this entirely — only a test that calls `arm(_:)` for a key needs to
/// `release(_:)` it later.
actor CallGate {
    private var armed: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var released: Set<String> = []

    func arm(_ key: String) { armed.insert(key) }

    func wait(for key: String) async {
        guard armed.contains(key), !released.contains(key) else { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    func release(_ key: String) {
        released.insert(key)
        let continuations = waiters.removeValue(forKey: key) ?? []
        for continuation in continuations { continuation.resume() }
    }
}

// MARK: - MachineDirectoryApiClient

actor FakeMachineDirectoryApi: MachineDirectoryApiClient {
    private(set) var callCount = 0
    var result: Result<[Machine], PaiError> = .success([])

    func getMachines() async throws -> [Machine] {
        callCount += 1
        switch result {
        case let .success(machines): return machines
        case let .failure(error): throw error
        }
    }
}

// MARK: - ClaudeAuthApiClient

actor FakeClaudeAuthApi: ClaudeAuthApiClient {
    private(set) var getCallCount = 0
    private(set) var startLoginCallCount = 0
    private(set) var submitCodeCalls: [(loginId: String, code: String)] = []
    private(set) var cancelLoginCallCount = 0

    var getResult: Result<ClaudeAuth, PaiError> = .success(
        ClaudeAuth(
            known: false, loggedIn: nil, subscription: nil, accessExpiresAt: nil, refreshExpiresAt: nil,
            login: nil, lastError: nil, reportedAt: nil
        ))
    var startLoginResult: Result<ClaudeAuth, PaiError>?
    var submitCodeResult: Result<ClaudeLoginCodeResponse, PaiError>?
    var cancelLoginResult: Result<ClaudeAuth, PaiError>?

    func getClaudeAuth() async throws -> ClaudeAuth {
        getCallCount += 1
        switch getResult {
        case let .success(auth): return auth
        case let .failure(error): throw error
        }
    }

    func startClaudeLogin() async throws -> ClaudeAuth {
        startLoginCallCount += 1
        guard let startLoginResult else { return try unwrap(getResult) }
        switch startLoginResult {
        case let .success(auth): return auth
        case let .failure(error): throw error
        }
    }

    func submitClaudeLoginCode(loginId: String, code: String) async throws -> ClaudeLoginCodeResponse {
        submitCodeCalls.append((loginId, code))
        guard let submitCodeResult else {
            throw PaiError.transport("no submitCodeResult scripted")
        }
        switch submitCodeResult {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }

    func cancelClaudeLogin() async throws -> ClaudeAuth {
        cancelLoginCallCount += 1
        guard let cancelLoginResult else { return try unwrap(getResult) }
        switch cancelLoginResult {
        case let .success(auth): return auth
        case let .failure(error): throw error
        }
    }

    private func unwrap(_ result: Result<ClaudeAuth, PaiError>) throws -> ClaudeAuth {
        switch result {
        case let .success(auth): return auth
        case let .failure(error): throw error
        }
    }
}

// MARK: - SubagentListApiClient

actor FakeSubagentListApi: SubagentListApiClient {
    struct GetSessionsCall: Equatable {
        let cursor: String?
        let kind: SessionKind?
        let parent: String?
    }

    private(set) var calls: [GetSessionsCall] = []
    /// FIFO per call — each `getSessions` call pulls the next queued result, so a test can script
    /// a first page and a distinct top-page refresh independently.
    var results: [Result<SessionsPage, PaiError>] = [.success(SessionsPage(sessions: [], nextCursor: nil))]

    func getSessions(
        since: String?, limit: Int?, cursor: String?, agent: String?, kind: SessionKind?, parent: String?, q: String?
    ) async throws -> SessionsPage {
        calls.append(GetSessionsCall(cursor: cursor, kind: kind, parent: parent))
        let result =
            results.count > 1
            ? results.removeFirst() : (results.first ?? .success(SessionsPage(sessions: [], nextCursor: nil)))
        switch result {
        case let .success(page): return page
        case let .failure(error): throw error
        }
    }
}

// MARK: - CreateSessionApiClient

actor FakeCreateSessionApi: CreateSessionApiClient {
    private(set) var postMessageCalls:
        [(sessionId: String?, message: String, sessionType: String?, workingDir: String?, agent: String?)] = []
    var sessionTypesResult: Result<[SessionType], PaiError> = .success([])
    var postMessageResult: Result<PostMessageResponse, PaiError> = .success(
        PostMessageResponse(sessionId: "new-session-id", messageId: 1)
    )

    func getSessionTypes() async throws -> [SessionType] {
        switch sessionTypesResult {
        case let .success(types): return types
        case let .failure(error): throw error
        }
    }

    func postMessage(
        sessionId: String?, message: String, files: [PaiFileUpload], sessionType: String?, workingDir: String?,
        agent: String?
    ) async throws -> PostMessageResponse {
        postMessageCalls.append(
            (sessionId: sessionId, message: message, sessionType: sessionType, workingDir: workingDir, agent: agent)
        )
        switch postMessageResult {
        case let .success(response): return response
        case let .failure(error): throw error
        }
    }
}

// MARK: - DirectoryBrowseApiClient

actor FakeDirectoryBrowseApi: DirectoryBrowseApiClient {
    private(set) var browseCalls: [(path: String?, agent: String?)] = []
    var browseResult: Result<BrowseResult, PaiError> = .success(BrowseResult(path: "/", directories: [], roots: []))
    var favorites: [FolderFavorite] = []
    var addFavoriteResult: Result<FolderFavorite, PaiError>?
    var removeFavoriteResult: Result<PaiFavoriteRemovalResult, PaiError>?

    func browse(path: String?, agent: String?) async throws -> BrowseResult {
        browseCalls.append((path: path, agent: agent))
        switch browseResult {
        case let .success(result): return result
        case let .failure(error): throw error
        }
    }

    func getFavorites() async throws -> [FolderFavorite] { favorites }

    func addFavorite(path: String) async throws -> FolderFavorite {
        if let addFavoriteResult {
            switch addFavoriteResult {
            case let .success(favorite): return favorite
            case let .failure(error): throw error
            }
        }
        let favorite = FolderFavorite(path: path, createdAt: nil)
        favorites.append(favorite)
        return favorite
    }

    func removeFavorite(path: String) async throws -> PaiFavoriteRemovalResult {
        if let removeFavoriteResult {
            switch removeFavoriteResult {
            case let .success(result): return result
            case let .failure(error): throw error
            }
        }
        favorites.removeAll { $0.path == path }
        return PaiFavoriteRemovalResult(path: path, removed: true)
    }
}

// MARK: - SessionActionsApiClient

actor FakeSessionActionsApi: SessionActionsApiClient {
    private(set) var renameCalls: [(sessionId: String, title: String)] = []
    private(set) var setTitleLockedCalls: [(sessionId: String, locked: Bool)] = []
    private(set) var closeCalls: [String] = []
    private(set) var setIdleTimeoutCalls: [(sessionId: String, minutes: Int?)] = []
    private(set) var exportCalls: [(sessionId: String, since: String?)] = []

    var sessionResult: Result<Session, PaiError> = .success(SessionFixture.make())
    var closeResult: Result<CloseResponse, PaiError> = .success(CloseResponse(status: .closed, detail: nil))
    var exportResult: Result<PaiExportResult, PaiError> = .success(
        PaiExportResult(data: Data(), filename: "export.json"))

    func renameSession(sessionId: String, title: String) async throws -> Session {
        renameCalls.append((sessionId, title))
        return try unwrap(sessionResult)
    }

    func setTitleLocked(sessionId: String, locked: Bool) async throws -> Session {
        setTitleLockedCalls.append((sessionId, locked))
        return try unwrap(sessionResult)
    }

    func closeSession(sessionId: String) async throws -> CloseResponse {
        closeCalls.append(sessionId)
        return try unwrap(closeResult)
    }

    func setIdleTimeout(sessionId: String, minutes: Int?) async throws -> Session {
        setIdleTimeoutCalls.append((sessionId, minutes))
        return try unwrap(sessionResult)
    }

    func exportSession(sessionId: String, since: String?) async throws -> PaiExportResult {
        exportCalls.append((sessionId, since))
        return try unwrap(exportResult)
    }

    private func unwrap<T>(_ result: Result<T, PaiError>) throws -> T {
        switch result {
        case let .success(value): return value
        case let .failure(error): throw error
        }
    }
}

// MARK: - Fixtures

enum SessionFixture {
    static func make(
        id: String = "s1",
        sessionType: String = "default",
        status: SessionStatus = .active,
        state: SessionState? = .ready,
        working: Bool? = nil,
        presenceState: SessionPresenceState? = nil,
        title: String? = nil,
        initialMessage: String? = nil,
        sessionTokens: Int = 0,
        createdAt: String? = "2026-01-01T00:00:00Z",
        updatedAt: String? = "2026-01-01T00:00:00Z",
        lastActivityAt: String? = "2026-01-01T00:00:00Z",
        workingDir: String? = nil,
        agent: String? = nil,
        kind: SessionKind? = .conversation,
        claudeSessionId: String? = nil,
        projectName: String? = nil,
        parentSessionId: String? = nil,
        subagentName: String? = nil,
        subagentType: String? = nil,
        discovered: Bool? = nil,
        activityCounts: ActivityCounts? = nil
    ) -> Session {
        Session(
            id: id,
            sessionType: sessionType,
            status: status,
            state: state,
            blocker: nil,
            working: working,
            presenceState: presenceState,
            title: title,
            titleLocked: nil,
            initialMessage: initialMessage,
            sessionTokens: sessionTokens,
            claudeSessionId: claudeSessionId,
            idleTimeoutMinutes: nil,
            effectiveIdleTimeoutMinutes: nil,
            cseId: nil,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActivityAt: lastActivityAt,
            workingDir: workingDir,
            agent: agent,
            kind: kind,
            parentSessionId: parentSessionId,
            subagentName: subagentName,
            subagentType: subagentType,
            subagentDescription: nil,
            remoteControl: nil,
            discovered: discovered,
            projectId: nil,
            phaseId: nil,
            projectName: projectName,
            activityCounts: activityCounts
        )
    }
}
