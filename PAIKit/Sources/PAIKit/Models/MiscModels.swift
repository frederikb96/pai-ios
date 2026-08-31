import Foundation

/// Swift port of the remaining sections of `pai-cloud/web/src/api/types.ts`: drafts, folder
/// favorites, plan usage, browse, health, Claude sign-in, auth, app secrets, SMTP settings, and
/// the small named API response shapes. Grouped together because each is a handful of fields
/// with no shared story, unlike `SessionModels.swift` / `MessageModels.swift` /
/// `StreamingModels.swift`.

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

// MARK: - Activity counts

/// What a session has running right now: subagents working for it, and background shells plus
/// monitors it started and has not stopped. Derived from the transcript at ingest, so it is only
/// ever as fresh as the last entry — see `pai-cloud/backend/src/pai_cloud/activity.py`.
public struct ActivityCounts: Codable, Sendable, Equatable {
    public let agents: Int
    public let tasks: Int

    public init(agents: Int, tasks: Int) {
        self.agents = agents
        self.tasks = tasks
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

/// A weekly cap that applies to one model rather than the whole plan.
public struct ScopedUsageWindow: Codable, Sendable, Equatable {
    public let model: String
    public let utilization: Double
    /// Absent while the window has not started counting.
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case model, utilization
        case resetsAt = "resets_at"
    }

    public init(model: String, utilization: Double, resetsAt: String?) {
        self.model = model
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

/// Windows are absent when the agent has not reported recently.
public struct Usage: Codable, Sendable, Equatable {
    public let fiveHour: UsageWindow?
    public let sevenDay: UsageWindow?
    /// Missing from an agent too old to report per-model caps.
    public let sevenDayModels: [ScopedUsageWindow]?
    public let reportedAt: String?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayModels = "seven_day_models"
        case reportedAt = "reported_at"
    }

    public init(
        fiveHour: UsageWindow?, sevenDay: UsageWindow?, sevenDayModels: [ScopedUsageWindow]?, reportedAt: String?
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.sevenDayModels = sevenDayModels
        self.reportedAt = reportedAt
    }
}

// MARK: - Browse

public struct BrowseResult: Codable, Sendable, Equatable {
    public let path: String
    public let directories: [String]
    /// The folders this machine allows browsing. Empty from an agent too old to report them —
    /// read that as "no boundary known", never as "nothing allowed".
    public let roots: [String]

    public init(path: String, directories: [String], roots: [String]) {
        self.path = path
        self.directories = directories
        self.roots = roots
    }
}

// MARK: - Health

/// Every field is a plain `String` rather than a closed enum. A literal this type does not know
/// would fail the whole decode, taking the health check down instead of mis-labelling one badge
/// — and this is the endpoint that reports whether anything is wrong, so it is the last one that
/// should break first.
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

/// What the VM's stored credential is actually worth. `signedOut` is the credential file's own
/// verdict; `rejected` is Anthropic's — the file is present and parses fine, and the account will
/// not accept it. Neither can launch a session, so both drive the same UI and differ only in
/// wording.
///
/// `.unrecognized` rather than throwing, for the reason `BlockerKind` documents: a value this
/// build has not heard of must not fail the whole decode of an auth snapshot the UI needs.
public enum CredentialHealth: Sendable, Hashable {
    case ok, rejected, signedOut
    case unrecognized(String)
}

extension CredentialHealth: Codable {
    private static let knownValues: [String: CredentialHealth] = [
        "ok": .ok,
        "rejected": .rejected,
        "signed_out": .signedOut,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ok: try container.encode("ok")
        case .rejected: try container.encode("rejected")
        case .signedOut: try container.encode("signed_out")
        case .unrecognized(let raw): try container.encode(raw)
        }
    }
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
///
/// 🚨 `loggedIn` means "a session can be launched right now", **not** "a credential file
/// exists". Deciding it any other way — most temptingly by comparing `refreshExpiresAt` against
/// the clock — is what let the web UI stay silent through an outage in which the access token
/// had died, every request came back 401, and the refresh token was still a month from expiring.
/// There is one authority on this question and it is the agent: read `loggedIn`, and use
/// `health` only to choose the wording.
public struct ClaudeAuth: Codable, Sendable, Equatable {
    public let known: Bool
    public let loggedIn: Bool?
    /// Why, when `loggedIn` is false — and which of the two stories to tell.
    public let health: CredentialHealth?
    /// Epoch ms Anthropic started refusing the credential; nil while it accepts it.
    public let rejectedSince: Double?
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
        case health
        case rejectedSince = "rejected_since"
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
        health: CredentialHealth? = nil,
        rejectedSince: Double? = nil,
        subscription: String?,
        accessExpiresAt: Double?,
        refreshExpiresAt: Double?,
        login: ClaudeLogin?,
        lastError: String?,
        reportedAt: String?
    ) {
        self.known = known
        self.loggedIn = loggedIn
        self.health = health
        self.rejectedSince = rejectedSince
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
    public let health: CredentialHealth?
    public let rejectedSince: Double?
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
        case health
        case rejectedSince = "rejected_since"
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
        health: CredentialHealth? = nil,
        rejectedSince: Double? = nil,
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
        self.health = health
        self.rejectedSince = rejectedSince
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
            health: health,
            rejectedSince: rejectedSince,
            subscription: subscription,
            accessExpiresAt: accessExpiresAt,
            refreshExpiresAt: refreshExpiresAt,
            login: login,
            lastError: lastError,
            reportedAt: reportedAt
        )
    }
}

// MARK: - Auth

/// There is one user, and every route is owner-only — sharing a session with another person
/// comes back as access for sandboxed agents, never as a guest role, so this carries no second
/// case to guard against. See `pai-cloud/.claude/CLAUDE.md` "There is one user, and every route
/// is owner-only".
public enum UserRole: String, Codable, Sendable, Equatable {
    case owner
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

/// Resuming a session PAI is not currently driving — one it started itself and closed, or one it
/// only ever observed. The same managed launch either way; see `docs/ARCHITECTURE.md` "Session
/// lifecycle".
public struct ResumeResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case resumed
        case alreadyRunning = "already_running"
        case refused
    }
    public let status: Status
    public let detail: String?
    /// The session as the launch left it. Absent from a backend that predates this field, in
    /// which case the caller waits for its next poll instead — see `PaiApiClient.resumeSession`.
    public let session: Session?

    public init(status: Status, detail: String?, session: Session?) {
        self.status = status
        self.detail = detail
        self.session = session
    }
}

// MARK: - App secrets
//
// A secret's value never appears in any of these — every shape here is presence and a
// timestamp, or a short-lived third-party token, never the stored value itself.

/// Every allowlisted secret name the backend currently recognizes.
public enum SecretName: String, Sendable, Equatable {
    case elevenlabs
    case smtpPassword = "smtp_password"
}

public struct SecretStatus: Codable, Sendable, Equatable {
    public let set: Bool
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case set
        case updatedAt = "updated_at"
    }

    public init(set: Bool, updatedAt: String?) {
        self.set = set
        self.updatedAt = updatedAt
    }
}

/// `types.ts` types this as `Partial<Record<SecretName, SecretStatus>>` — an object keyed by
/// whichever of the two allowlisted names the backend chose to report, both optional. A plain
/// `[String: SecretStatus]` would decode a JSON *array* of alternating keys and values rather
/// than the object the backend actually sends (`Dictionary`'s synthesized `Decodable` only takes
/// the keyed-object path for `String`/`Int` keys via a raw string fast path, which a
/// `RawRepresentable` enum key does not qualify for) — named fields sidestep that entirely.
public struct SecretStatusMap: Codable, Sendable, Equatable {
    public let elevenlabs: SecretStatus?
    public let smtpPassword: SecretStatus?

    enum CodingKeys: String, CodingKey {
        case elevenlabs
        case smtpPassword = "smtp_password"
    }

    public init(elevenlabs: SecretStatus?, smtpPassword: SecretStatus?) {
        self.elevenlabs = elevenlabs
        self.smtpPassword = smtpPassword
    }
}

public struct VoiceToken: Codable, Sendable, Equatable {
    public let token: String
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case token
        case expiresIn = "expires_in"
    }

    public init(token: String, expiresIn: Int) {
        self.token = token
        self.expiresIn = expiresIn
    }
}

// MARK: - SMTP settings
//
// Everything about how PAI sends its own alert mail except the password, which is a separate
// write-only secret (`smtp_password`, see `SecretStatusMap` above) and never appears here.

/// See `SessionStatus`'s doc comment for why `.unrecognized` exists rather than throwing.
public enum SmtpSecurity: Sendable, Hashable {
    case ssl, starttls, none
    case unrecognized(String)
}

extension SmtpSecurity: Codable {
    private static let knownValues: [String: SmtpSecurity] = [
        "ssl": .ssl, "starttls": .starttls, "none": .none,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ssl: try container.encode("ssl")
        case .starttls: try container.encode("starttls")
        case .none: try container.encode("none")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

public struct SmtpSettings: Codable, Sendable, Equatable {
    public let host: String?
    public let port: Int
    public let security: SmtpSecurity
    public let username: String?
    public let fromAddress: String?
    public let recipient: String
    public let enabled: Bool
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case host, port, security, username
        case fromAddress = "from_address"
        case recipient, enabled
        case updatedAt = "updated_at"
    }

    public init(
        host: String?, port: Int, security: SmtpSecurity, username: String?, fromAddress: String?,
        recipient: String, enabled: Bool, updatedAt: String
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.fromAddress = fromAddress
        self.recipient = recipient
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

/// Any subset of `SmtpSettings`'s writable fields (everything but `updatedAt`) — the server
/// leaves an omitted key as-is.
///
/// ⚠️ Every field here is a plain `Optional`, which Swift's synthesized `Encodable` omits from
/// the wire when `nil` — so this type can express "leave `host` alone" (by never setting it) but
/// cannot express "clear `host` to null" (setting it to `Optional.some(nil)` and an omitted key
/// look identical once encoded). The web client never needs the second case either: its Save
/// button PUTs the whole draft object every time, values and blanks alike, never a selective
/// patch. Match that pattern here — populate every field before sending — until an actual need
/// for a real tri-state patch shows up.
public struct SmtpSettingsUpdate: Encodable, Sendable, Equatable {
    public var host: String?
    public var port: Int?
    public var security: SmtpSecurity?
    public var username: String?
    public var fromAddress: String?
    public var recipient: String?
    public var enabled: Bool?

    enum CodingKeys: String, CodingKey {
        case host, port, security, username
        case fromAddress = "from_address"
        case recipient, enabled
    }

    public init(
        host: String? = nil, port: Int? = nil, security: SmtpSecurity? = nil, username: String? = nil,
        fromAddress: String? = nil, recipient: String? = nil, enabled: Bool? = nil
    ) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
        self.fromAddress = fromAddress
        self.recipient = recipient
        self.enabled = enabled
    }
}
