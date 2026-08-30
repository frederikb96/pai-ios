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

// --- Session kind ---

/// `.subagent` names a Claude Code sub-conversation nested under a parent `Session` — entirely
/// unrelated to `Machine` (the physical box PAI can watch or drive). The two are easy to
/// conflate because both compile everywhere either would fit; see `Machine`'s doc comment for
/// the full warning. See `SessionStatus`'s doc comment for why `.unrecognized` exists.
public enum SessionKind: Sendable, Hashable {
    case conversation, subagent
    case unrecognized(String)
}

extension SessionKind: Codable {
    private static let knownValues: [String: SessionKind] = [
        "conversation": .conversation, "subagent": .subagent,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .conversation: try container.encode("conversation")
        case .subagent: try container.encode("subagent")
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
    /// Absent on a row written before its first agent round-trip — the UI falls back to
    /// `status` in that window. See `docs/ARCHITECTURE.md` "Session lifecycle" for the five
    /// values and what each means for the composer.
    public let state: SessionState?
    public let blocker: Blocker?
    /// Whether Claude is actively mid-turn, read off the agent's own `worker_status` on an
    /// otherwise-`ready` session. `nil` for every other state and for the agent's own
    /// unspecified value — never read a `nil` here as "idle".
    public let working: Bool?
    public let title: String?
    /// True once the name was chosen by hand. For a conversation with a `phaseId`, setting
    /// `title` locks that PHASE against the auto-summariser — the same lock every other
    /// session sharing the phase sees — not just this row; a session with no phase yet, or a
    /// subagent, keeps the plain per-row lock the VM's own naming respects.
    public let titleLocked: Bool?
    public let initialMessage: String?
    public let pendingMessage: String?
    public let sessionTokens: Int
    /// Claude's own conversation uuid — what `claude --resume` takes.
    public let claudeSessionId: String?
    /// How long this session may sit idle before it is closed, in minutes. `nil` follows the
    /// deployment's default; `0` means it never closes.
    public let idleTimeoutMinutes: Int?
    /// The same, resolved — `nil` here means it never closes.
    public let effectiveIdleTimeoutMinutes: Int?
    /// Remote Control's session id. Nil until the session has registered with it.
    public let cseId: String?
    public let createdAt: String?
    public let updatedAt: String?
    public let lastActivityAt: String?
    public let workingDir: String?
    /// The machine this session lives on (a `Machine`'s `slug`). Absent on a row from a
    /// backend that predates multi-agent — read a `nil` here as the VM, since that was every
    /// session's only home until now. A plain `String`, not `Machine`, deliberately: nothing
    /// about this field is the machine-overload trap `Machine`'s doc comment describes.
    public let agent: String?
    /// `.subagent` transcripts never appear as top-level rows — see `parentSessionId`.
    public let kind: SessionKind?
    /// Set only on a subagent: the conversation that spawned it.
    public let parentSessionId: String?
    /// A subagent's own name, when its `.meta.json` sidecar has one — an in-process teammate's
    /// chosen name, not its type. `nil` for a plain Task subagent, which has no name distinct
    /// from `subagentType`.
    public let subagentName: String?
    /// A subagent's type (`Explore`, `aria`, `general-purpose`, …) — the sidecar's
    /// `customAgentType` when present, else its `agentType` for a plain Task subagent. `nil`
    /// for an in-process teammate whose sidecar carries neither, since `agentType` there holds
    /// the name instead.
    public let subagentType: String?
    public let subagentDescription: String?
    /// The model Claude Code recorded for this subagent, from its `.meta.json` sidecar or the
    /// spawning `Task` call. `nil` for well over half of them — a spawn that named no model
    /// inherits one, and the backend refuses to guess which, since the agent definition's
    /// frontmatter is mutable and an env override is invisible. Read a `nil` as unknown, never
    /// as a default.
    public let subagentModel: String?
    /// Where Freddy last stopped reading this transcript, persisted so returning to it restores
    /// the same position across a reload or a different device. `readPositionAtBottom` is `nil`
    /// until a position has ever been recorded; `true` means "go straight to the live edge" and
    /// beats the other two, which are `nil` together in that case. The anchor is a MESSAGE id
    /// plus an offset within it, never a scroll offset alone — rows are virtualized, so
    /// everything above the reader changes height as it lays out.
    public let readPositionMessageId: Int?
    public let readPositionOffsetPx: Int?
    public let readPositionAtBottom: Bool?
    /// Whether this CONVERSATION has ever registered with Remote Control — historical and
    /// monotonic, never a statement about whether PAI can drive it now. That question is
    /// `state`; see `docs/ARCHITECTURE.md` "What decides whether a session can be typed into".
    public let remoteControl: Bool?
    /// True for a session PAI never launched — found by the transcript watcher.
    public let discovered: Bool?
    /// The memory-system project/phase this conversation belongs to — `nil` until a hook, a
    /// rename, or a switch has placed it. A conversation's name IS its current phase's name.
    public let projectId: String?
    public let phaseId: String?
    /// The project's own name, denormalized here so the session list's search can match on it.
    public let projectName: String?
    /// What this session has running right now — subagents and background shells/monitors.
    /// `nil` from an agent too old to report it, read the same as "nothing known", never as zero.
    public let activityCounts: ActivityCounts?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionType = "session_type"
        case status, state, blocker, working, title
        case titleLocked = "title_locked"
        case initialMessage = "initial_message"
        case pendingMessage = "pending_message"
        case sessionTokens = "session_tokens"
        case claudeSessionId = "claude_session_id"
        case idleTimeoutMinutes = "idle_timeout_minutes"
        case effectiveIdleTimeoutMinutes = "effective_idle_timeout_minutes"
        case cseId = "cse_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastActivityAt = "last_activity_at"
        case workingDir = "working_dir"
        case agent, kind
        case parentSessionId = "parent_session_id"
        case subagentName = "subagent_name"
        case subagentType = "subagent_type"
        case subagentDescription = "subagent_description"
        case subagentModel = "subagent_model"
        case readPositionMessageId = "read_position_message_id"
        case readPositionOffsetPx = "read_position_offset_px"
        case readPositionAtBottom = "read_position_at_bottom"
        case remoteControl = "remote_control"
        case discovered
        case projectId = "project_id"
        case phaseId = "phase_id"
        case projectName = "project_name"
        case activityCounts = "activity_counts"
    }

    public init(
        id: String,
        sessionType: String,
        status: SessionStatus,
        state: SessionState?,
        blocker: Blocker?,
        working: Bool?,
        title: String?,
        titleLocked: Bool?,
        initialMessage: String?,
        pendingMessage: String?,
        sessionTokens: Int,
        claudeSessionId: String?,
        idleTimeoutMinutes: Int?,
        effectiveIdleTimeoutMinutes: Int?,
        cseId: String?,
        createdAt: String?,
        updatedAt: String?,
        lastActivityAt: String?,
        workingDir: String?,
        agent: String?,
        kind: SessionKind?,
        parentSessionId: String?,
        subagentName: String?,
        subagentType: String?,
        subagentDescription: String?,
        subagentModel: String? = nil,
        readPositionMessageId: Int? = nil,
        readPositionOffsetPx: Int? = nil,
        readPositionAtBottom: Bool? = nil,
        remoteControl: Bool?,
        discovered: Bool?,
        projectId: String?,
        phaseId: String?,
        projectName: String?,
        activityCounts: ActivityCounts? = nil
    ) {
        self.id = id
        self.sessionType = sessionType
        self.status = status
        self.state = state
        self.blocker = blocker
        self.working = working
        self.title = title
        self.titleLocked = titleLocked
        self.initialMessage = initialMessage
        self.pendingMessage = pendingMessage
        self.sessionTokens = sessionTokens
        self.claudeSessionId = claudeSessionId
        self.idleTimeoutMinutes = idleTimeoutMinutes
        self.effectiveIdleTimeoutMinutes = effectiveIdleTimeoutMinutes
        self.cseId = cseId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastActivityAt = lastActivityAt
        self.workingDir = workingDir
        self.agent = agent
        self.kind = kind
        self.parentSessionId = parentSessionId
        self.subagentName = subagentName
        self.subagentType = subagentType
        self.subagentDescription = subagentDescription
        self.subagentModel = subagentModel
        self.readPositionMessageId = readPositionMessageId
        self.readPositionOffsetPx = readPositionOffsetPx
        self.readPositionAtBottom = readPositionAtBottom
        self.remoteControl = remoteControl
        self.discovered = discovered
        self.projectId = projectId
        self.phaseId = phaseId
        self.projectName = projectName
        self.activityCounts = activityCounts
    }

    /// A copy with the session-level fields of a live SSE `status` event applied — the same
    /// three-plus-one fields `TranscriptStore.LiveSessionStatus` carries, and nothing else,
    /// because that event never reports any other column this type holds.
    public func withLiveStatus(
        state: SessionState?, blocker: Blocker?, working: Bool?, activityCounts: ActivityCounts?
    ) -> Session {
        Session(
            id: id, sessionType: sessionType, status: status, state: state, blocker: blocker, working: working,
            title: title, titleLocked: titleLocked, initialMessage: initialMessage, pendingMessage: pendingMessage,
            sessionTokens: sessionTokens, claudeSessionId: claudeSessionId, idleTimeoutMinutes: idleTimeoutMinutes,
            effectiveIdleTimeoutMinutes: effectiveIdleTimeoutMinutes, cseId: cseId, createdAt: createdAt,
            updatedAt: updatedAt, lastActivityAt: lastActivityAt, workingDir: workingDir, agent: agent, kind: kind,
            parentSessionId: parentSessionId, subagentName: subagentName, subagentType: subagentType,
            subagentDescription: subagentDescription, subagentModel: subagentModel,
            readPositionMessageId: readPositionMessageId, readPositionOffsetPx: readPositionOffsetPx,
            readPositionAtBottom: readPositionAtBottom, remoteControl: remoteControl, discovered: discovered,
            projectId: projectId, phaseId: phaseId, projectName: projectName, activityCounts: activityCounts
        )
    }
}

/// One `GET /api/sessions/search` result — a `Session` plus how it matched. `score` is `nil`
/// for a fuzzy hit (its scale is an internal ranking device, not comparable across queries) and
/// a 0-1 cosine similarity for a semantic one.
///
/// `types.ts` expresses this as a TS structural extension (`Session & {score}`); Swift has no
/// struct inheritance, and duplicating every one of `Session`'s ~25 fields here would be exactly
/// the kind of drift this whole file exists to avoid. Delegating both `Codable` directions to
/// `Session` itself keeps this one field the only thing this type says.
public struct SessionSearchResult: Codable, Sendable, Equatable, Identifiable {
    public var id: String { session.id }
    public let session: Session
    public let score: Double?

    private enum ScoreCodingKeys: String, CodingKey { case score }

    public init(session: Session, score: Double?) {
        self.session = session
        self.score = score
    }

    public init(from decoder: Decoder) throws {
        session = try Session(from: decoder)
        let container = try decoder.container(keyedBy: ScoreCodingKeys.self)
        score = try container.decodeIfPresent(Double.self, forKey: .score)
    }

    public func encode(to encoder: Encoder) throws {
        try session.encode(to: encoder)
        var container = encoder.container(keyedBy: ScoreCodingKeys.self)
        try container.encode(score, forKey: .score)
    }
}

/// One page of `GET /api/sessions`, plus the opaque token for the next one. `nextCursor` is
/// `nil` once there is no further page — pass it straight back as `cursor`; never derive one
/// from a row. The cursor rides the `X-Next-Cursor` response header, not the body, which is why
/// `PaiApiClient.getSessions` bypasses its usual JSON-decoding path to assemble this.
public struct SessionsPage: Sendable, Equatable {
    public let sessions: [Session]
    public let nextCursor: String?

    public init(sessions: [Session], nextCursor: String?) {
        self.sessions = sessions
        self.nextCursor = nextCursor
    }
}

public struct SessionType: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let icon: String
    /// Present only on a per-machine session-type list (`Machine.sessionTypes`) — the launch
    /// directory that type opens in on that particular machine.
    public let workingDir: String?

    enum CodingKeys: String, CodingKey {
        case id, name, icon
        case workingDir = "working_dir"
    }

    public init(id: String, name: String, icon: String, workingDir: String? = nil) {
        self.id = id
        self.name = name
        self.icon = icon
        self.workingDir = workingDir
    }
}

// --- Machines ---

/// A machine PAI can watch or drive — the VM, or Freddy's laptop while it is logged in. `types.ts`
/// names this `Agent`, which this port deliberately does not: `Session.kind == .subagent` names a
/// Claude Code sub-conversation, an entirely different thing, and keeping both called "agent" in
/// Swift produces code that typechecks while meaning the wrong one. `Machine` and `SessionKind`
/// are the two halves of that split.
public struct Machine: Codable, Sendable, Equatable, Identifiable {
    public var id: String { slug }
    public let slug: String
    public let displayName: String
    public let online: Bool
    public let lastSeenAt: String?
    public let ingestEnabled: Bool
    public let capabilities: Capabilities
    public let sessionTypes: [SessionType]
    /// Progress of the machine's whole-tree backfill. `nil` once pending work reaches zero, or
    /// before anything has been reported — both read as no backfill.
    public let backfill: Backfill?

    public struct Capabilities: Codable, Sendable, Equatable {
        public let fastSessions: Bool
        public let reboot: Bool
        public let shell: Bool

        enum CodingKeys: String, CodingKey {
            case fastSessions = "fast_sessions"
            case reboot, shell
        }

        public init(fastSessions: Bool, reboot: Bool, shell: Bool) {
            self.fastSessions = fastSessions
            self.reboot = reboot
            self.shell = shell
        }
    }

    /// Every field is present only if the agent reported it.
    public struct Backfill: Codable, Sendable, Equatable {
        public let totalFiles: Int?
        public let completeFiles: Int?
        public let totalBytes: Int?
        public let shippedBytes: Int?
        public let pendingBytes: Int?

        enum CodingKeys: String, CodingKey {
            case totalFiles = "total_files"
            case completeFiles = "complete_files"
            case totalBytes = "total_bytes"
            case shippedBytes = "shipped_bytes"
            case pendingBytes = "pending_bytes"
        }

        public init(
            totalFiles: Int? = nil,
            completeFiles: Int? = nil,
            totalBytes: Int? = nil,
            shippedBytes: Int? = nil,
            pendingBytes: Int? = nil
        ) {
            self.totalFiles = totalFiles
            self.completeFiles = completeFiles
            self.totalBytes = totalBytes
            self.shippedBytes = shippedBytes
            self.pendingBytes = pendingBytes
        }
    }

    enum CodingKeys: String, CodingKey {
        case slug
        case displayName = "display_name"
        case online
        case lastSeenAt = "last_seen_at"
        case ingestEnabled = "ingest_enabled"
        case capabilities
        case sessionTypes = "session_types"
        case backfill
    }

    public init(
        slug: String,
        displayName: String,
        online: Bool,
        lastSeenAt: String?,
        ingestEnabled: Bool,
        capabilities: Capabilities,
        sessionTypes: [SessionType],
        backfill: Backfill? = nil
    ) {
        self.slug = slug
        self.displayName = displayName
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.ingestEnabled = ingestEnabled
        self.capabilities = capabilities
        self.sessionTypes = sessionTypes
        self.backfill = backfill
    }
}
