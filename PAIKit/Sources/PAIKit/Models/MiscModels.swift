import Foundation

/// Swift port of the remaining sections of `pai-cloud/web/src/api/types.ts`: drafts, folder
/// favorites, plan usage, browse, health, Claude sign-in, auth, app secrets, SMTP settings, and
/// the small named API response shapes. Grouped together because each is a handful of fields
/// with no shared story, unlike `SessionModels.swift` / `MessageModels.swift` /
/// `StreamingModels.swift`.

// MARK: - Drafts

/// One file added to a draft, uploaded to the server immediately rather than held on the device
/// that picked it — so a message can be composed from several devices at once.
///
/// `state` starts `uploading` and becomes `stored` or `failed`; a thumbnail shown for a `failed`
/// upload would be a claim of cross-device visibility the system does not have. `unclaimed` is
/// the one a send produces: the file is on the server and the move onto the session did not
/// happen, so the message went without it and the next send will try again.
///
/// Deliberately a `String` rather than an enum: an unknown value from a newer backend must render
/// as an ordinary attachment, not fail the whole draft's decode.
public struct DraftAttachment: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let filename: String
    public let path: String
    public let size: Int
    public let contentType: String?
    public let state: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, filename, path, size
        case contentType = "content_type"
        case state
        case createdAt = "created_at"
    }

    public init(
        id: String, filename: String, path: String, size: Int, contentType: String?,
        state: String, createdAt: String
    ) {
        self.id = id
        self.filename = filename
        self.path = path
        self.size = size
        self.contentType = contentType
        self.state = state
        self.createdAt = createdAt
    }
}

/// Composer text that has not been sent yet, kept on the server so every client shows the same
/// half-written message. `key` is a session id, or `"new"` for the not-yet-created session the
/// New Session screen composes — only that draft carries `sessionType`/`workingDir`, its launch
/// choices.
///
/// **No CAS, no conflict.** `version` is the only thing a client orders by (`DraftStore`'s own
/// adoption rule: strictly greater than what this device last recorded, and only into a clean
/// entry) — `updatedAt` stays for display only and must never be compared for ordering, which is
/// exactly the bug this version field replaces.
public struct Draft: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public let key: String
    public let text: String
    public let sessionType: String?
    public let workingDir: String?
    /// The `claude --model` alias this draft's session will launch with — only meaningful on the
    /// `"new"` draft, alongside `sessionType`/`workingDir`. `nil` lets Claude Code pick the
    /// plan's own default rather than naming one.
    public let model: String?
    /// The `claude --effort` level this draft's session will launch with — same "new" draft-only
    /// scoping as `model` above. `nil` lets Claude Code pick the plan's own default.
    public let thinking: String?
    public let updatedAt: String?
    /// Server-assigned, `+1` on every write to the row, including a clear. The only field a
    /// client may order by.
    public let version: Int
    /// The writer's own device id — diagnostics and a "recording on <device>" hint only, never
    /// consulted for an ownership decision on this device.
    public let deviceId: String?
    /// What the row held immediately before this write — a one-level undo a composer can offer
    /// as "Restore earlier version". `nil`/empty means there is nothing to restore.
    public let previousText: String?
    public let attachments: [DraftAttachment]

    enum CodingKeys: String, CodingKey {
        case key, text
        case sessionType = "session_type"
        case workingDir = "working_dir"
        case model, thinking
        case updatedAt = "updated_at"
        case version
        case deviceId = "device_id"
        case previousText = "previous_text"
        case attachments
    }

    public init(
        key: String, text: String, sessionType: String?, workingDir: String?, model: String? = nil,
        thinking: String? = nil, updatedAt: String?, version: Int = 0, deviceId: String? = nil,
        previousText: String? = nil, attachments: [DraftAttachment] = []
    ) {
        self.key = key
        self.text = text
        self.sessionType = sessionType
        self.workingDir = workingDir
        self.model = model
        self.thinking = thinking
        self.updatedAt = updatedAt
        self.version = version
        self.deviceId = deviceId
        self.previousText = previousText
        self.attachments = attachments
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

/// What a session has running right now: `agents` is every subagent still alive — busy or idle,
/// since an idle one can be handed more work at any moment — and `tasks` is the background
/// shells and monitors it started and has not stopped. Derived from the transcript at ingest, so
/// it is only ever as fresh as the last entry — see `pai-cloud/backend/src/pai_cloud/activity.py`.
public struct ActivityCounts: Codable, Sendable, Equatable {
    public let agents: Int
    public let tasks: Int

    public init(agents: Int, tasks: Int) {
        self.agents = agents
        self.tasks = tasks
    }
}

// MARK: - Gated-secret prompt

/// A session waiting for Freddy to unlock the gated secrets it was refused, raised by the session
/// itself rather than by anyone opening a menu. `names` is the machine's own record of those
/// refusals — the same set the grant acts on — and none of it is secret; the passphrase that
/// answers the prompt goes straight to the grant route and is never stored anywhere.
public struct SecretPrompt: Codable, Sendable, Equatable {
    /// When the session raised it.
    public let at: String
    public let names: [String]
    /// What the session said it needs them for, if it said anything.
    public let reason: String?

    public init(at: String, names: [String], reason: String?) {
        self.at = at
        self.names = names
        self.reason = reason
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
    /// `true` when this answer came from a `client_message_id` already on record rather than a
    /// fresh insert — the idempotent replay path. A caller has nothing further to do either way:
    /// the message was accepted exactly once.
    public let duplicate: Bool
    /// The version of the draft this send consumed and cleared, so the sender's own next poll is
    /// a no-op and another device's composer reads empty without anyone issuing a delete.
    public let draftVersion: Int?
    /// The send was pulled back into the composer (Escape-undo) before it was delivered, so the
    /// server refused it: nothing was enqueued and the draft was not touched. Only ever set on a
    /// ``duplicate`` answer — and when it is, the sender must NOT treat the send as accepted.
    public let withdrawn: Bool
    /// With ``withdrawn``: the server's own draft already holds this text (a row withdrawn after
    /// it arrived). `false` means the sender holds the only copy and must put it back itself.
    public let textInDraft: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case messageId = "message_id"
        case duplicate
        case draftVersion = "draft_version"
        case withdrawn
        case textInDraft = "text_in_draft"
    }

    public init(
        sessionId: String, messageId: Int, duplicate: Bool = false, draftVersion: Int? = nil,
        withdrawn: Bool = false, textInDraft: Bool = false
    ) {
        self.sessionId = sessionId
        self.messageId = messageId
        self.duplicate = duplicate
        self.draftVersion = draftVersion
        self.withdrawn = withdrawn
        self.textInDraft = textInDraft
    }

    /// A hand-written `init` rather than the synthesized one: `duplicate` defaults to `false`
    /// when the key is absent, so a fixture or test response written before this field existed
    /// still decodes rather than failing every send in the corpus at once.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        messageId = try container.decode(Int.self, forKey: .messageId)
        duplicate = try container.decodeIfPresent(Bool.self, forKey: .duplicate) ?? false
        draftVersion = try container.decodeIfPresent(Int.self, forKey: .draftVersion)
        withdrawn = try container.decodeIfPresent(Bool.self, forKey: .withdrawn) ?? false
        textInDraft = try container.decodeIfPresent(Bool.self, forKey: .textInDraft) ?? false
    }
}

/// One withdrawn send's own content — `POST /api/session/{id}/withdraw-pending`'s `withdrawn[]`.
public struct WithdrawnSend: Codable, Sendable, Equatable {
    /// The outbox row's own id — the same id a `PendingSend` carries.
    public let id: Int
    public let text: String
    /// Ties the row back to the caller's own entry; `nil` for a row some other client sent.
    public let clientMessageId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case text
        case clientMessageId = "client_message_id"
    }

    public init(id: Int, text: String, clientMessageId: String? = nil) {
        self.id = id
        self.text = text
        self.clientMessageId = clientMessageId
    }
}

/// `POST /api/session/{id}/withdraw-pending`'s reply. Every row counted as pending when the
/// route ran falls into exactly one of ``withdrawn`` (pulled back — carries its text, oldest
/// first), ``alreadyDelivered`` (the agent had already consumed it; left untouched) or
/// ``unresolved`` (a relay that errored whose fate the wire could not settle; left untouched).
/// The server also rewrites the session's own draft from ``withdrawn``'s texts and bumps its
/// version to ``draftVersion``, which is informational here: the client builds the composer text
/// from ``withdrawn`` directly rather than waiting on a draft poll to catch up.
///
/// The request may name `client_message_ids` — sends the caller holds that may already have left
/// it. Of those, ``withdrawnClientIds`` are now withdrawn (a send the server never saw was
/// tombstoned, so it has no row in ``withdrawn`` and its text is the caller's own),
/// ``deliveredClientIds`` reached Claude, and an id in neither is undecided.
public struct WithdrawPendingResponse: Codable, Sendable, Equatable {
    public let withdrawn: [WithdrawnSend]
    /// Outbox ids the agent had already consumed — their bubbles stay exactly as a confirmed
    /// send would, nothing pulled back for them.
    public let alreadyDelivered: [Int]
    public let unresolved: [Int]
    public let withdrawnClientIds: [String]
    public let deliveredClientIds: [String]
    public let draftVersion: Int

    enum CodingKeys: String, CodingKey {
        case withdrawn
        case alreadyDelivered = "already_delivered"
        case unresolved
        case withdrawnClientIds = "withdrawn_client_ids"
        case deliveredClientIds = "delivered_client_ids"
        case draftVersion = "draft_version"
    }

    public init(
        withdrawn: [WithdrawnSend], alreadyDelivered: [Int], draftVersion: Int, unresolved: [Int] = [],
        withdrawnClientIds: [String] = [], deliveredClientIds: [String] = []
    ) {
        self.withdrawn = withdrawn
        self.alreadyDelivered = alreadyDelivered
        self.unresolved = unresolved
        self.withdrawnClientIds = withdrawnClientIds
        self.deliveredClientIds = deliveredClientIds
        self.draftVersion = draftVersion
    }

    /// The three lists an older server does not send decode as empty rather than failing the
    /// whole answer: the rest of the shape is unchanged.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        withdrawn = try container.decode([WithdrawnSend].self, forKey: .withdrawn)
        alreadyDelivered = try container.decode([Int].self, forKey: .alreadyDelivered)
        unresolved = try container.decodeIfPresent([Int].self, forKey: .unresolved) ?? []
        withdrawnClientIds = try container.decodeIfPresent([String].self, forKey: .withdrawnClientIds) ?? []
        deliveredClientIds = try container.decodeIfPresent([String].self, forKey: .deliveredClientIds) ?? []
        draftVersion = try container.decode(Int.self, forKey: .draftVersion)
    }
}

/// `POST /api/session/{id}/send-now` — what became of making Claude take its queued messages.
public struct SendNowResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case nothingQueued = "nothing_queued"
        case sent
        case refused
        case unavailable
        case notApplicable = "not_applicable"
    }

    /// Why the agent would not press the key. An unknown value decodes as ``paneUnreadable`` —
    /// the answer that tells the user to try again — rather than failing the whole reply.
    public enum Reason: String, Codable, Sendable, Equatable {
        case blocked
        case promptHasDraft = "prompt_has_draft"
        case paneUnreadable = "pane_unreadable"
        case notRunning = "not_running"

        public init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Reason(rawValue: raw) ?? .paneUnreadable
        }
    }

    public let status: Status
    /// With ``Status/sent``: outbox ids Claude took.
    public let delivered: [Int]
    /// With ``Status/sent``: outbox ids Claude is holding for a reason of its own.
    public let stillQueued: [Int]
    public let reason: Reason?

    enum CodingKeys: String, CodingKey {
        case status
        case delivered
        case stillQueued = "still_queued"
        case reason
    }

    public init(status: Status, delivered: [Int] = [], stillQueued: [Int] = [], reason: Reason? = nil) {
        self.status = status
        self.delivered = delivered
        self.stillQueued = stillQueued
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        delivered = try container.decodeIfPresent([Int].self, forKey: .delivered) ?? []
        stillQueued = try container.decodeIfPresent([Int].self, forKey: .stillQueued) ?? []
        reason = try container.decodeIfPresent(Reason.self, forKey: .reason)
    }
}

/// `POST /api/session/{id}/background` — what became of moving the running foreground command
/// (or subagent) to the background.
public struct MoveToBackgroundResponse: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable, Equatable {
        case nothingRunning = "nothing_running"
        case moved
        case refused
        case unavailable
        case notApplicable = "not_applicable"
    }

    public let status: Status
    public let moved: [String]
    public let notMoved: [String]
    /// With ``Status/refused``: the worker's own words.
    public let reason: String?

    enum CodingKeys: String, CodingKey {
        case status
        case moved
        case notMoved = "not_moved"
        case reason
    }

    public init(status: Status, moved: [String] = [], notMoved: [String] = [], reason: String? = nil) {
        self.status = status
        self.moved = moved
        self.notMoved = notMoved
        self.reason = reason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(Status.self, forKey: .status)
        moved = try container.decodeIfPresent([String].self, forKey: .moved) ?? []
        notMoved = try container.decodeIfPresent([String].self, forKey: .notMoved) ?? []
        reason = try container.decodeIfPresent(String.self, forKey: .reason)
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

public struct ReadPositionAck: Codable, Sendable, Equatable {
    public let ok: Bool

    public init(ok: Bool) {
        self.ok = ok
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

/// Every allowlisted secret name a client can set. The backend's own allowlist
/// (`secrets_store.ALLOWED_SECRET_NAMES`) holds more — `vapid` and `apns_auth_key` are managed
/// by their own flows, never typed into a field.
public enum SecretName: String, Sendable, Equatable {
    case elevenlabs
    case smtpPassword = "smtp_password"
    case homeAssistantToken = "home_assistant_token"
    case todoistToken = "todoist_token"
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
/// whichever allowlisted names the backend chose to report, each optional. A plain
/// `[String: SecretStatus]` would decode a JSON *array* of alternating keys and values rather
/// than the object the backend actually sends (`Dictionary`'s synthesized `Decodable` only takes
/// the keyed-object path for `String`/`Int` keys via a raw string fast path, which a
/// `RawRepresentable` enum key does not qualify for) — named fields sidestep that entirely.
public struct SecretStatusMap: Codable, Sendable, Equatable {
    public let elevenlabs: SecretStatus?
    public let smtpPassword: SecretStatus?
    public let homeAssistantToken: SecretStatus?
    public let todoistToken: SecretStatus?

    enum CodingKeys: String, CodingKey {
        case elevenlabs
        case smtpPassword = "smtp_password"
        case homeAssistantToken = "home_assistant_token"
        case todoistToken = "todoist_token"
    }

    public init(
        elevenlabs: SecretStatus?,
        smtpPassword: SecretStatus?,
        homeAssistantToken: SecretStatus? = nil,
        todoistToken: SecretStatus? = nil
    ) {
        self.elevenlabs = elevenlabs
        self.smtpPassword = smtpPassword
        self.homeAssistantToken = homeAssistantToken
        self.todoistToken = todoistToken
    }

    /// The status for one name, so a view drawing a field per name does not need a switch
    /// per call site — one place that knows which stored property each name maps to.
    public func status(for name: SecretName) -> SecretStatus? {
        switch name {
        case .elevenlabs: elevenlabs
        case .smtpPassword: smtpPassword
        case .homeAssistantToken: homeAssistantToken
        case .todoistToken: todoistToken
        }
    }
}

// MARK: - Voice settings
//
// How the two spoken voices sound. Computer speaks through OpenAI Realtime, which names a voice
// and has no speed parameter — delivery there is shaped by telling the model how to speak. A
// session's call-mode replies go through ElevenLabs, which takes a voice id and a speed and no
// instructions. A `nil` means unset: whatever speaks picks its own.

/// What the number input offers. The backend validates the real bound
/// (`models.CALL_SPEED_MIN`/`MAX`) and answers 400 outside it; this project has no OpenAPI
/// schema to share one constant from, the same duplication `SmtpSecurity`'s own value list
/// already carries for the same reason.
public let callSpeedRange: ClosedRange<Double> = 0.5...2.0

public struct SpokenVoiceSettings: Codable, Sendable, Equatable {
    public let computerVoice: String?
    public let computerDelivery: String?
    public let callVoiceId: String?
    public let callSpeed: Double
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case computerVoice = "computer_voice"
        case computerDelivery = "computer_delivery"
        case callVoiceId = "call_voice_id"
        case callSpeed = "call_speed"
        case updatedAt = "updated_at"
    }

    public init(
        computerVoice: String?, computerDelivery: String?, callVoiceId: String?,
        callSpeed: Double, updatedAt: String
    ) {
        self.computerVoice = computerVoice
        self.computerDelivery = computerDelivery
        self.callVoiceId = callVoiceId
        self.callSpeed = callSpeed
        self.updatedAt = updatedAt
    }
}

/// Every field every time, the same whole-draft PUT `SmtpSettingsUpdate` sends and for the same
/// reason: a `nil` here has to reach the server as JSON `null` to clear a field, which a
/// selective patch cannot express.
public struct SpokenVoiceSettingsUpdate: Encodable, Sendable, Equatable {
    public var computerVoice: String?
    public var computerDelivery: String?
    public var callVoiceId: String?
    public var callSpeed: Double

    enum CodingKeys: String, CodingKey {
        case computerVoice = "computer_voice"
        case computerDelivery = "computer_delivery"
        case callVoiceId = "call_voice_id"
        case callSpeed = "call_speed"
    }

    public init(
        computerVoice: String?, computerDelivery: String?, callVoiceId: String?, callSpeed: Double
    ) {
        self.computerVoice = computerVoice
        self.computerDelivery = computerDelivery
        self.callVoiceId = callVoiceId
        self.callSpeed = callSpeed
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

/// A grant of the whole gated store armed for the next session a client creates, before that
/// session exists — `GET/PUT/DELETE /api/secret-pregrant`. One slot the backend holds in memory,
/// shared with the web, so a client only ever reads it back rather than remembering it.
public struct SecretPregrantStatus: Codable, Sendable, Equatable {
    public let armed: Bool
    /// How long the grant lasts once applied; `nil` when nothing is armed.
    public let ttlSeconds: Int?
    /// When an unused armed grant is dropped; `nil` when nothing is armed.
    public let discardAt: String?

    enum CodingKeys: String, CodingKey {
        case armed
        case ttlSeconds = "ttl_seconds"
        case discardAt = "discard_at"
    }

    public init(armed: Bool, ttlSeconds: Int?, discardAt: String?) {
        self.armed = armed
        self.ttlSeconds = ttlSeconds
        self.discardAt = discardAt
    }
}
