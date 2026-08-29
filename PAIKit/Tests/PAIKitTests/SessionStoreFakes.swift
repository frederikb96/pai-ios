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

// MARK: - Fixtures

enum SessionFixture {
    static func make(
        id: String = "s1",
        sessionType: String = "default",
        status: SessionStatus = .active,
        state: SessionState? = .ready,
        working: Bool? = nil,
        title: String? = nil,
        initialMessage: String? = nil,
        sessionTokens: Int = 0,
        createdAt: String? = "2026-01-01T00:00:00Z",
        updatedAt: String? = "2026-01-01T00:00:00Z",
        lastActivityAt: String? = "2026-01-01T00:00:00Z",
        workingDir: String? = nil,
        agent: String? = nil,
        kind: SessionKind? = .conversation,
        claudeSessionId: String? = nil
    ) -> Session {
        Session(
            id: id,
            sessionType: sessionType,
            status: status,
            state: state,
            blocker: nil,
            working: working,
            title: title,
            titleLocked: nil,
            initialMessage: initialMessage,
            pendingMessage: nil,
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
            parentSessionId: nil,
            subagentName: nil,
            subagentType: nil,
            subagentDescription: nil,
            remoteControl: nil,
            discovered: nil,
            projectId: nil,
            phaseId: nil,
            projectName: nil
        )
    }
}
