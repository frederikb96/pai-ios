import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` (the "Session Status" / "Session" sections).
/// `pai-cloud` owns this contract; this file mirrors it rather than redefining it.

/// Not a plain `String` raw-value enum: `getSessions()` decodes `[Session]` in one shot, so a
/// closed enum that throws on a status this build predates would blank the *entire* list rather
/// than degrade the one row carrying it. `.unrecognized` keeps the row decodable and carries the
/// raw string forward, matching how `HealthResponse` already treats a backend/client mismatch as
/// expected rather than fatal.
public enum SessionStatus: Sendable, Hashable {
    case pending, active, completed, error, interrupted, deleted
    case unrecognized(String)
}

extension SessionStatus: Codable {
    private static let knownValues: [String: SessionStatus] = [
        "pending": .pending, "active": .active, "completed": .completed,
        "error": .error, "interrupted": .interrupted, "deleted": .deleted,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("pending")
        case .active: try container.encode("active")
        case .completed: try container.encode("completed")
        case .error: try container.encode("error")
        case .interrupted: try container.encode("interrupted")
        case .deleted: try container.encode("deleted")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// Optional on `Session` because a row written before its first agent round-trip has neither
/// `state` nor `blocker` yet — the UI falls back to the `status` badge in that window.
/// See `SessionStatus`'s doc comment for why `.unrecognized` exists rather than throwing.
public enum SessionState: Sendable, Hashable {
    case starting, ready, blocked, attention, closed
    case unrecognized(String)
}

extension SessionState: Codable {
    private static let knownValues: [String: SessionState] = [
        "starting": .starting, "ready": .ready, "blocked": .blocked,
        "attention": .attention, "closed": .closed,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .starting: try container.encode("starting")
        case .ready: try container.encode("ready")
        case .blocked: try container.encode("blocked")
        case .attention: try container.encode("attention")
        case .closed: try container.encode("closed")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// See `SessionStatus`'s doc comment for why `.unrecognized` exists rather than throwing.
/// `.unknown` is different: it is the backend's own explicit `"unknown"` blocker kind, a real
/// value `types.ts` declares — not a decode fallback.
public enum BlockerKind: Sendable, Hashable {
    case trustPrompt, trustPromptConfirmed, loginRequired, permissionPrompt, choicePrompt
    case unknown
    case unrecognized(String)
}

extension BlockerKind: Codable {
    private static let knownValues: [String: BlockerKind] = [
        "trust_prompt": .trustPrompt,
        "trust_prompt_confirmed": .trustPromptConfirmed,
        "login_required": .loginRequired,
        "permission_prompt": .permissionPrompt,
        "choice_prompt": .choicePrompt,
        "unknown": .unknown,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .trustPrompt: try container.encode("trust_prompt")
        case .trustPromptConfirmed: try container.encode("trust_prompt_confirmed")
        case .loginRequired: try container.encode("login_required")
        case .permissionPrompt: try container.encode("permission_prompt")
        case .choicePrompt: try container.encode("choice_prompt")
        case .unknown: try container.encode("unknown")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

public struct BlockerOption: Codable, Sendable, Equatable {
    public let key: String
    public let label: String

    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

public struct Blocker: Codable, Sendable, Equatable {
    public let kind: BlockerKind
    public let question: String
    public let options: [BlockerOption]

    public init(kind: BlockerKind, question: String, options: [BlockerOption]) {
        self.kind = kind
        self.question = question
        self.options = options
    }
}

public struct Session: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let sessionType: String
    public let status: SessionStatus
    public let state: SessionState?
    public let blocker: Blocker?
    public let title: String?
    /// True once the name was chosen by hand; the VM stops naming it then.
    public let titleLocked: Bool?
    public let initialMessage: String?
    public let pendingMessage: String?
    public let sessionTokens: Int
    /// Claude's own conversation uuid — what `claude --resume` takes.
    public let claudeSessionId: String?
    /// Remote Control's session id. Nil until the session has registered with it.
    public let cseId: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let lastActivityAt: String?
    public let workingDir: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionType = "session_type"
        case status, state, blocker, title
        case titleLocked = "title_locked"
        case initialMessage = "initial_message"
        case pendingMessage = "pending_message"
        case sessionTokens = "session_tokens"
        case claudeSessionId = "claude_session_id"
        case cseId = "cse_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastActivityAt = "last_activity_at"
        case workingDir = "working_dir"
    }

    public init(
        id: String,
        sessionType: String,
        status: SessionStatus,
        state: SessionState?,
        blocker: Blocker?,
        title: String?,
        titleLocked: Bool?,
        initialMessage: String?,
        pendingMessage: String?,
        sessionTokens: Int,
        claudeSessionId: String?,
        cseId: String?,
        createdAt: String?,
        updatedAt: String?,
        lastActivityAt: String?,
        workingDir: String?
    ) {
        self.id = id
        self.sessionType = sessionType
        self.status = status
        self.state = state
        self.blocker = blocker
        self.title = title
        self.titleLocked = titleLocked
        self.initialMessage = initialMessage
        self.pendingMessage = pendingMessage
        self.sessionTokens = sessionTokens
        self.claudeSessionId = claudeSessionId
        self.cseId = cseId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.workingDir = workingDir
    }
}

public struct SessionType: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let icon: String

    public init(id: String, name: String, icon: String) {
        self.id = id
        self.name = name
        self.icon = icon
    }
}
