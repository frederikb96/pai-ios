import Foundation

/// Swift port of the remaining sections of `pai-cloud/web/src/api/types.ts`: drafts, folder
/// favorites, plan usage, browse, health, Claude sign-in, auth/sharing, and the small named API
/// response shapes. Grouped together because each is a handful of fields with no shared story,
/// unlike `SessionModels.swift` / `MessageModels.swift` / `StreamingModels.swift`.

// MARK: - Drafts

/// Composer text that has not been sent yet, kept on the server so every client shows the same
/// half-written message. `key` is a session id, or `"new"` for the not-yet-created session the
/// New Session screen composes — only that draft carries `sessionType`/`workingDir`, its launch
/// choices.
public struct Draft: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let text: String
    public let sessionType: String?
    public let workingDir: String?
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case key, text
        case sessionType = "session_type"
        case workingDir = "working_dir"
        case updatedAt = "updated_at"
    }

    public init(key: String, text: String, sessionType: String?, workingDir: String?, updatedAt: String?) {
        self.key = key
        self.text = text
        self.sessionType = sessionType
        self.workingDir = workingDir
        self.updatedAt = updatedAt
    }
}

// MARK: - Folder favorites

/// A VM folder marked as a shortcut in the Custom picker. Server-stored, not local, so the
/// browser and the phone agree.
public struct FolderFavorite: Codable, Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case path
        case createdAt = "created_at"
    }

    public init(path: String, createdAt: String?) {
        self.path = path
        self.createdAt = createdAt
    }
}

// MARK: - Plan usage

public struct UsageWindow: Codable, Sendable, Equatable {
    /// Percent of the window consumed.
    public let utilization: Double
    public let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    public init(utilization: Double, resetsAt: String) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// Windows are absent when the agent has not reported recently.
public struct Usage: Codable, Sendable, Equatable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    public let reportedAt: String?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case reportedAt = "reported_at"
    }

    public init(fiveHour: UsageWindow?, sevenDay: UsageWindow?, reportedAt: String?) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.reportedAt = reportedAt
    }
}

// MARK: - Browse

public struct BrowseResult: Codable, Sendable, Equatable {
    public let path: String
    public let directories: [String]

    public init(path: String, directories: [String]) {
        self.path = path
        self.directories = directories
    }
}

// MARK: - Health

/// `types.ts` declares `status: 'ok' | 'degraded'`, but the running backend
/// (`backend/src/pai_cloud/api.py`, `health()`) actually returns `'ok' | 'unavailable'` for
/// `status`/`database`, and adds a `credential` field the TS type does not declare at all. The
/// two disagree; since a wrong literal here would fail decoding entirely rather than just
/// mis-displaying a badge, every field is a plain `String` instead of a closed enum matching
/// either source, and `credential` is included as the actual backend sends it.
public struct HealthResponse: Codable, Sendable, Equatable {
    public let status: String
    public let database: String
    public let agent: String
    public let credential: String?
    public let timestamp: String

    public init(status: String, database: String, agent: String, credential: String?, timestamp: String) {
        self.status = status
        self.database = database
        self.agent = agent
        self.credential = credential
        self.timestamp = timestamp
    }
}

// MARK: - Claude sign-in on the VM

public enum ClaudeLoginState: String, Codable, Sendable, Equatable {
    case awaitingCode = "awaiting_code"
    case verifying
}

public struct ClaudeLogin: Codable, Sendable, Equatable {
    public let id: String
    /// The authorize URL to open. Whole — never a fragment read off a screen.
    public let url: String
    public let state: ClaudeLoginState
    public let startedAt: Double

    enum CodingKeys: String, CodingKey {
        case id, url, state
        case startedAt = "started_at"
    }

    public init(id: String, url: String, state: ClaudeLoginState, startedAt: Double) {
        self.id = id
        self.url = url
        self.state = state
        self.startedAt = startedAt
    }
}

/// What the VM reports about its Claude credential. `known` is false while the agent is
/// silent — different from "signed out" — so the UI must not raise an alarm about a state
/// nobody actually reported.
public struct ClaudeAuth: Codable, Sendable, Equatable {
    public let known: Bool
    public let loggedIn: Bool?
    public let subscription: String?
    /// Epoch ms the short-lived access token expires. Refreshed automatically.
    public let accessExpiresAt: Double?
    /// Epoch ms a real re-sign-in becomes unavoidable. The date worth warning about.
    public let refreshExpiresAt: Double?
    public let login: ClaudeLogin?
    public let lastError: String?
    public let reportedAt: String?

    enum CodingKeys: String, CodingKey {
        case known
        case loggedIn = "logged_in"
        case subscription
        case accessExpiresAt = "access_expires_at"
        case refreshExpiresAt = "refresh_expires_at"
        case login
        case lastError = "last_error"
        case reportedAt = "reported_at"
    }

    public init(
        known: Bool,
        loggedIn: Bool?,
        subscription: String?,
        accessExpiresAt: Double?,
        refreshExpiresAt: Double?,
        login: ClaudeLogin?,
        lastError: String?,
        reportedAt: String?
    ) {
        self.known = known
        self.loggedIn = loggedIn
        self.subscription = subscription
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.login = login
        self.lastError = lastError
        self.reportedAt = reportedAt
    }
}

/// `types.ts` declares this as `ClaudeAuth & {ok, error?}` — TS structural extension over a
/// flat JSON object. Swift has no struct inheritance, so every `ClaudeAuth` field is repeated
/// here rather than composed, matching the one flat response body the server actually sends.
public struct ClaudeLoginCodeResponse: Codable, Sendable, Equatable {
    public let known: Bool
    public let loggedIn: Bool?
    public let subscription: String?
    public let accessExpiresAt: Double?
    public let refreshExpiresAt: Double?
    public let login: ClaudeLogin?
    public let lastError: String?
    public let reportedAt: String?
    public let ok: Bool
    public let error: String?

    enum CodingKeys: String, CodingKey {
        case known
        case loggedIn = "logged_in"
        case subscription
        case accessExpiresAt = "access_expires_at"
        case refreshExpiresAt = "refresh_expires_at"
        case login
        case lastError = "last_error"
        case reportedAt = "reported_at"
        case ok, error
    }

    public init(
        known: Bool,
        loggedIn: Bool?,
        subscription: String?,
        accessExpiresAt: Double?,
        refreshExpiresAt: Double?,
        login: ClaudeLogin?,
        lastError: String?,
        reportedAt: String?,
        ok: Bool,
        error: String?
    ) {
        self.known = known
        self.loggedIn = loggedIn
        self.subscription = subscription
        self.accessExpiresAt = accessExpiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.login = login
        self.lastError = lastError
        self.reportedAt = reportedAt
        self.ok = ok
        self.error = error
    }

    /// The `ClaudeAuth` half of this response, for call sites that store/compare it as one.
    public var auth: ClaudeAuth {
        ClaudeAuth(
            known: known,
            loggedIn: loggedIn,
            subscription: subscription,
            accessExpiresAt: accessExpiresAt,
            refreshExpiresAt: refreshExpiresAt,
            login: login,
            lastError: lastError,
            reportedAt: reportedAt
        )
    }
}

// MARK: - Auth / sharing

public enum UserRole: String, Codable, Sendable, Equatable {
    case owner, guest
}

public struct MeResponse: Codable, Sendable, Equatable {
    public let identity: String
    public let role: UserRole
    public let allowedSessionIds: [String]

    enum CodingKeys: String, CodingKey {
        case identity, role
        case allowedSessionIds = "allowed_session_ids"
    }

    public init(identity: String, role: UserRole, allowedSessionIds: [String]) {
        self.identity = identity
        self.role = role
        self.allowedSessionIds = allowedSessionIds
    }
}

public struct KnownUser: Codable, Sendable, Equatable, Identifiable {
    public var id: String { email }
    public let email: String
    public let displayName: String?

    enum CodingKeys: String, CodingKey {
        case email
        case displayName = "display_name"
    }

    public init(email: String, displayName: String?) {
        self.email = email
        self.displayName = displayName
    }
}

public struct SessionShare: Codable, Sendable, Equatable, Identifiable {
    public enum Role: String, Codable, Sendable, Equatable { case guest }
    public var id: String { email }
    public let email: String
    public let role: Role
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case email, role
        case createdAt = "created_at"
    }

    public init(email: String, role: Role, createdAt: String?) {
        self.email = email
        self.role = role
        self.createdAt = createdAt
    }
}

// MARK: - Small named API response shapes

public struct PostMessageResponse: Codable, Sendable, Equatable {
    public let sessionId: String
    public let messageId: Int

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messageId = "message_id"
    }

    public init(sessionId: String, messageId: Int) {
        self.sessionId = sessionId
        self.messageId = messageId
    }
}

public struct CancelResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable { case cancelled }
    public let status: Status

    public init(status: Status) {
        self.status = status
    }
}

public struct CloseResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case closed
        case alreadyClosed = "already_closed"
        case closeError = "close_error"
    }
    public let status: Status
    public let detail: String?

    public init(status: Status, detail: String?) {
        self.status = status
        self.detail = detail
    }
}

public struct DeleteResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case deleted
        case alreadyDeleted = "already_deleted"
    }
    public let status: Status

    public init(status: Status) {
        self.status = status
    }
}

public struct AnswerBlockerResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case ok
        case noBlocker = "no_blocker"
        case error
    }
    public let status: Status
    public let detail: String?

    public init(status: Status, detail: String?) {
        self.status = status
        self.detail = detail
    }
}
