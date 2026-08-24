import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` (the "Session Status" / "Session" sections).
/// `pai-cloud` owns this contract; this file mirrors it rather than redefining it.

public enum SessionStatus: String, Codable, Sendable, Equatable {
    case pending, active, completed, error, interrupted, deleted
}

/// Optional on `Session` because a row written before its first agent round-trip has neither
/// `state` nor `blocker` yet — the UI falls back to the `status` badge in that window.
public enum SessionState: String, Codable, Sendable, Equatable {
    case starting, ready, blocked, attention, closed
}

public enum BlockerKind: String, Codable, Sendable, Equatable {
    case trustPrompt = "trust_prompt"
    case trustPromptConfirmed = "trust_prompt_confirmed"
    case loginRequired = "login_required"
    case permissionPrompt = "permission_prompt"
    case choicePrompt = "choice_prompt"
    case unknown
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
