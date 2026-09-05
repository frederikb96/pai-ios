import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts`'s "The scheduler" section
/// (`ScheduledTask`, `ScheduledTaskDetail`, `TaskRun`, `Supervision`, `SupervisionVerdict`).
/// `pai-cloud` owns this contract; this file mirrors it rather than redefining it.
///
/// This is PAI's OWN scheduler — unrelated to Claude Code's in-session cron, which the
/// transcript parser merely recognises and never drives. See `docs/ARCHITECTURE.md`
/// ("PAI's scheduler, and Claude Code's own") in `pai-cloud` for the distinction.

/// How a task decides what happens to its session between fires. `.reuse` resumes the same
/// conversation, so context accumulates; `.fresh` starts a new one per fire; `.oneShot` fires
/// once and cleans up after itself.
public enum TaskSessionPolicy: Sendable, Hashable {
    case reuse, fresh, oneShot
    case unrecognized(String)
}

extension TaskSessionPolicy: Codable {
    private static let knownValues: [String: TaskSessionPolicy] = [
        "reuse": .reuse, "fresh": .fresh, "one_shot": .oneShot,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .reuse: try container.encode("reuse")
        case .fresh: try container.encode("fresh")
        case .oneShot: try container.encode("one_shot")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// When a run's declared result should reach the phone. `.onError` is the task-creation default
/// server-side: a watcher failing quietly is the failure the whole result contract exists to
/// prevent.
public enum TaskNotifyPolicy: Sendable, Hashable {
    case always, onFind, onError, never
    case unrecognized(String)
}

extension TaskNotifyPolicy: Codable {
    private static let knownValues: [String: TaskNotifyPolicy] = [
        "always": .always, "on_find": .onFind, "on_error": .onError, "never": .never,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .always: try container.encode("always")
        case .onFind: try container.encode("on_find")
        case .onError: try container.encode("on_error")
        case .never: try container.encode("never")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// Which runtime executes a gate script on the VM. Both resolve their own dependencies on
/// first use, so a script is one self-contained file and a new one never needs a container
/// rebuild.
public enum TaskGateRuntime: Sendable, Hashable {
    case bun, python
    case unrecognized(String)
}

extension TaskGateRuntime: Codable {
    private static let knownValues: [String: TaskGateRuntime] = [
        "bun": .bun, "python": .python,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .bun: try container.encode("bun")
        case .python: try container.encode("python")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// What the SCHEDULER did with a fire — distinct from what the agent then declared.
/// Collapsing the two loses the answer: *it ran and found nothing* is not *it checked and
/// declined* is not *it never fired at all*.
public enum TaskRunDisposition: Sendable, Hashable {
    case fired, declined, skipped, deferred, refused, error
    case unrecognized(String)
}

extension TaskRunDisposition: Codable {
    private static let knownValues: [String: TaskRunDisposition] = [
        "fired": .fired, "declined": .declined, "skipped": .skipped,
        "deferred": .deferred, "refused": .refused, "error": .error,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .fired: try container.encode("fired")
        case .declined: try container.encode("declined")
        case .skipped: try container.encode("skipped")
        case .deferred: try container.encode("deferred")
        case .refused: try container.encode("refused")
        case .error: try container.encode("error")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// What the AGENT declared at the end of its run. `.unknown` means the run ended without
/// declaring anything — its own outcome, which notifies once and then stays quiet, because a
/// broken watcher must never look like a patient one.
public enum TaskResultStatus: Sendable, Hashable {
    case found, nothing, error, unknown
    case unrecognized(String)
}

extension TaskResultStatus: Codable {
    private static let knownValues: [String: TaskResultStatus] = [
        "found": .found, "nothing": .nothing, "error": .error, "unknown": .unknown,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .found: try container.encode("found")
        case .nothing: try container.encode("nothing")
        case .error: try container.encode("error")
        case .unknown: try container.encode("unknown")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// What triggered one `TaskRun`.
public enum TaskRunTrigger: Sendable, Hashable {
    case schedule, webhook, manual
    case unrecognized(String)
}

extension TaskRunTrigger: Codable {
    private static let knownValues: [String: TaskRunTrigger] = [
        "schedule": .schedule, "webhook": .webhook, "manual": .manual,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .schedule: try container.encode("schedule")
        case .webhook: try container.encode("webhook")
        case .manual: try container.encode("manual")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// The binding's own state. `.stopped` is the ONE authority on whether the worker may be
/// resumed — see `Supervision`'s doc comment. `.degraded` means supervision itself is failing
/// and saying so, while forwarding continues, since pausing it fails silent and open.
public enum SupervisionState: Sendable, Hashable {
    case active, degraded, stopped, ended
    case unrecognized(String)
}

extension SupervisionState: Codable {
    private static let knownValues: [String: SupervisionState] = [
        "active": .active, "degraded": .degraded, "stopped": .stopped, "ended": .ended,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .active: try container.encode("active")
        case .degraded: try container.encode("degraded")
        case .stopped: try container.encode("stopped")
        case .ended: try container.encode("ended")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// One verdict from the supervisor watching a run. `.invalid` records an answer the hook
/// rejected — kept rather than discarded, so a degrading supervisor is visible instead of
/// merely quiet.
public enum SupervisionVerdictValue: Sendable, Hashable {
    case ok, warning, stop, invalid
    case unrecognized(String)
}

extension SupervisionVerdictValue: Codable {
    private static let knownValues: [String: SupervisionVerdictValue] = [
        "ok": .ok, "warning": .warning, "stop": .stop, "invalid": .invalid,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .ok: try container.encode("ok")
        case .warning: try container.encode("warning")
        case .stop: try container.encode("stop")
        case .invalid: try container.encode("invalid")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// `GET /api/scheduler/tasks` — one scheduled task.
///
/// `hasGate` and `hasWebhook` are booleans rather than the values themselves: a task list
/// would otherwise ship every script to render a table, and a webhook token is shown once at
/// creation and never again. `gateSource` arrives only on ``ScheduledTaskDetail``.
public struct ScheduledTask: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let environment: String
    public let workingDir: String?
    public let prompt: String
    /// Applied at launch, so it cannot reach a conversation already running — editing it on a
    /// reusing task changes nothing until the task is reset.
    public let appendSystemPrompt: String?
    /// Five-field cron. `nil` means the task fires only by webhook or by hand.
    public let cadence: String?
    public let timezone: String
    public let hasGate: Bool
    public let gateRuntime: TaskGateRuntime?
    public let gateTimeoutSeconds: Int
    public let sessionPolicy: TaskSessionPolicy
    public let sessionId: String?
    /// How long the transcript must be quiet before a run counts as over. Measured on the
    /// transcript, never on a wall clock: an agent waiting on a background job looks idle
    /// while being anything but.
    public let quietPeriodMinutes: Int
    public let autocompactTokens: Int?
    /// The `claude --model` alias the worker session launches with. `nil` lets Claude Code
    /// pick the plan's own default. Absent on a backend that predates it.
    public let model: String?
    /// A run's own runtime ceiling in minutes, watched at the next reading rather than at an
    /// exact instant. `nil`/absent means no ceiling.
    public let maxRuntimeMinutes: Int?
    /// A run's own token budget, covering the worker and every subagent it spawns.
    public let maxTokenBudget: Int?
    /// Above this, a reusing task's worker session is compacted before the task considers the
    /// run over. Replaces `autocompactTokens`, which nothing reads.
    public let compactionThresholdTokens: Int?
    /// A fire is skipped once the 5-hour plan window is at or above this percentage.
    public let sessionUsageGatePercent: Int?
    /// A fire is skipped once the 7-day plan window is at or above this percentage.
    public let weeklyUsageGatePercent: Int?
    /// Whether a gate-percentage skip raises an alert. Off by default.
    public let notifyOnGateSkip: Bool?
    public let supervisionEnabled: Bool
    public let supervisionModel: String?
    /// Pre-filled onto every `Supervision` this task's own fires create.
    public let supervisionAppendPrompt: String?
    public let supervisionCompactionThresholdTokens: Int?
    /// How often the worker's transcript is flushed to the supervisor.
    public let supervisionChunkIntervalSeconds: Int?
    /// The token size of accumulated worker output that forces an early flush regardless of
    /// the interval above.
    public let supervisionChunkTokenThreshold: Int?
    public let notifyPolicy: TaskNotifyPolicy
    /// An urgent task is never deferred when the plan window runs low.
    public let urgent: Bool
    public let hasWebhook: Bool
    /// Set by a supervisor stop, and terminal: the scheduler refuses to fire a stopped task
    /// until a person clears it.
    public let stopped: Bool
    public let stoppedReason: String?
    public let lastFireAtMs: Int?
    /// The heartbeat. Older than a multiple of the cadence means stale — the only thing
    /// distinguishing a watcher that found nothing from one that died months ago.
    public let lastSuccessAtMs: Int?
    public let nextFireAtMs: Int?
    public let createdAtMs: Int
    public let updatedAtMs: Int

    public init(
        id: String, name: String, enabled: Bool, environment: String, workingDir: String?,
        prompt: String, appendSystemPrompt: String?, cadence: String?, timezone: String,
        hasGate: Bool, gateRuntime: TaskGateRuntime?, gateTimeoutSeconds: Int,
        sessionPolicy: TaskSessionPolicy, sessionId: String?, quietPeriodMinutes: Int,
        autocompactTokens: Int?, model: String? = nil, maxRuntimeMinutes: Int? = nil,
        maxTokenBudget: Int? = nil, compactionThresholdTokens: Int? = nil,
        sessionUsageGatePercent: Int? = nil, weeklyUsageGatePercent: Int? = nil,
        notifyOnGateSkip: Bool? = nil, supervisionEnabled: Bool, supervisionModel: String?,
        supervisionAppendPrompt: String? = nil, supervisionCompactionThresholdTokens: Int? = nil,
        supervisionChunkIntervalSeconds: Int? = nil, supervisionChunkTokenThreshold: Int? = nil,
        notifyPolicy: TaskNotifyPolicy, urgent: Bool, hasWebhook: Bool, stopped: Bool,
        stoppedReason: String?, lastFireAtMs: Int?, lastSuccessAtMs: Int?, nextFireAtMs: Int?,
        createdAtMs: Int, updatedAtMs: Int
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.environment = environment
        self.workingDir = workingDir
        self.prompt = prompt
        self.appendSystemPrompt = appendSystemPrompt
        self.cadence = cadence
        self.timezone = timezone
        self.hasGate = hasGate
        self.gateRuntime = gateRuntime
        self.gateTimeoutSeconds = gateTimeoutSeconds
        self.sessionPolicy = sessionPolicy
        self.sessionId = sessionId
        self.quietPeriodMinutes = quietPeriodMinutes
        self.autocompactTokens = autocompactTokens
        self.model = model
        self.maxRuntimeMinutes = maxRuntimeMinutes
        self.maxTokenBudget = maxTokenBudget
        self.compactionThresholdTokens = compactionThresholdTokens
        self.sessionUsageGatePercent = sessionUsageGatePercent
        self.weeklyUsageGatePercent = weeklyUsageGatePercent
        self.notifyOnGateSkip = notifyOnGateSkip
        self.supervisionEnabled = supervisionEnabled
        self.supervisionModel = supervisionModel
        self.supervisionAppendPrompt = supervisionAppendPrompt
        self.supervisionCompactionThresholdTokens = supervisionCompactionThresholdTokens
        self.supervisionChunkIntervalSeconds = supervisionChunkIntervalSeconds
        self.supervisionChunkTokenThreshold = supervisionChunkTokenThreshold
        self.notifyPolicy = notifyPolicy
        self.urgent = urgent
        self.hasWebhook = hasWebhook
        self.stopped = stopped
        self.stoppedReason = stoppedReason
        self.lastFireAtMs = lastFireAtMs
        self.lastSuccessAtMs = lastSuccessAtMs
        self.nextFireAtMs = nextFireAtMs
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, environment, prompt, cadence, timezone, urgent, stopped, model
        case workingDir = "working_dir"
        case appendSystemPrompt = "append_system_prompt"
        case hasGate = "has_gate"
        case gateRuntime = "gate_runtime"
        case gateTimeoutSeconds = "gate_timeout_seconds"
        case sessionPolicy = "session_policy"
        case sessionId = "session_id"
        case quietPeriodMinutes = "quiet_period_minutes"
        case autocompactTokens = "autocompact_tokens"
        case maxRuntimeMinutes = "max_runtime_minutes"
        case maxTokenBudget = "max_token_budget"
        case compactionThresholdTokens = "compaction_threshold_tokens"
        case sessionUsageGatePercent = "session_usage_gate_percent"
        case weeklyUsageGatePercent = "weekly_usage_gate_percent"
        case notifyOnGateSkip = "notify_on_gate_skip"
        case supervisionEnabled = "supervision_enabled"
        case supervisionModel = "supervision_model"
        case supervisionAppendPrompt = "supervision_append_prompt"
        case supervisionCompactionThresholdTokens = "supervision_compaction_threshold_tokens"
        case supervisionChunkIntervalSeconds = "supervision_chunk_interval_seconds"
        case supervisionChunkTokenThreshold = "supervision_chunk_token_threshold"
        case notifyPolicy = "notify_policy"
        case hasWebhook = "has_webhook"
        case stoppedReason = "stopped_reason"
        case lastFireAtMs = "last_fire_at_ms"
        case lastSuccessAtMs = "last_success_at_ms"
        case nextFireAtMs = "next_fire_at_ms"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
    }
}

/// `GET /api/scheduler/tasks/{id}` — a task plus the gate script the list omits.
public struct ScheduledTaskDetail: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let enabled: Bool
    public let environment: String
    public let workingDir: String?
    public let prompt: String
    public let appendSystemPrompt: String?
    public let cadence: String?
    public let timezone: String
    public let hasGate: Bool
    public let gateRuntime: TaskGateRuntime?
    public let gateTimeoutSeconds: Int
    public let sessionPolicy: TaskSessionPolicy
    public let sessionId: String?
    public let quietPeriodMinutes: Int
    public let autocompactTokens: Int?
    /// The `claude --model` alias the worker session launches with. `nil` lets Claude Code
    /// pick the plan's own default. Absent on a backend that predates it.
    public let model: String?
    /// A run's own runtime ceiling in minutes, watched at the next reading rather than at an
    /// exact instant. `nil`/absent means no ceiling.
    public let maxRuntimeMinutes: Int?
    /// A run's own token budget, covering the worker and every subagent it spawns.
    public let maxTokenBudget: Int?
    /// Above this, a reusing task's worker session is compacted before the task considers the
    /// run over. Replaces `autocompactTokens`, which nothing reads.
    public let compactionThresholdTokens: Int?
    /// A fire is skipped once the 5-hour plan window is at or above this percentage.
    public let sessionUsageGatePercent: Int?
    /// A fire is skipped once the 7-day plan window is at or above this percentage.
    public let weeklyUsageGatePercent: Int?
    /// Whether a gate-percentage skip raises an alert. Off by default.
    public let notifyOnGateSkip: Bool?
    public let supervisionEnabled: Bool
    public let supervisionModel: String?
    /// Pre-filled onto every `Supervision` this task's own fires create.
    public let supervisionAppendPrompt: String?
    public let supervisionCompactionThresholdTokens: Int?
    /// How often the worker's transcript is flushed to the supervisor.
    public let supervisionChunkIntervalSeconds: Int?
    /// The token size of accumulated worker output that forces an early flush regardless of
    /// the interval above.
    public let supervisionChunkTokenThreshold: Int?
    public let notifyPolicy: TaskNotifyPolicy
    public let urgent: Bool
    public let hasWebhook: Bool
    public let stopped: Bool
    public let stoppedReason: String?
    public let lastFireAtMs: Int?
    public let lastSuccessAtMs: Int?
    public let nextFireAtMs: Int?
    public let createdAtMs: Int
    public let updatedAtMs: Int
    public let gateSource: String?

    public init(
        id: String, name: String, enabled: Bool, environment: String, workingDir: String?,
        prompt: String, appendSystemPrompt: String?, cadence: String?, timezone: String,
        hasGate: Bool, gateRuntime: TaskGateRuntime?, gateTimeoutSeconds: Int,
        sessionPolicy: TaskSessionPolicy, sessionId: String?, quietPeriodMinutes: Int,
        autocompactTokens: Int?, model: String? = nil, maxRuntimeMinutes: Int? = nil,
        maxTokenBudget: Int? = nil, compactionThresholdTokens: Int? = nil,
        sessionUsageGatePercent: Int? = nil, weeklyUsageGatePercent: Int? = nil,
        notifyOnGateSkip: Bool? = nil, supervisionEnabled: Bool, supervisionModel: String?,
        supervisionAppendPrompt: String? = nil, supervisionCompactionThresholdTokens: Int? = nil,
        supervisionChunkIntervalSeconds: Int? = nil, supervisionChunkTokenThreshold: Int? = nil,
        notifyPolicy: TaskNotifyPolicy, urgent: Bool, hasWebhook: Bool, stopped: Bool,
        stoppedReason: String?, lastFireAtMs: Int?, lastSuccessAtMs: Int?, nextFireAtMs: Int?,
        createdAtMs: Int, updatedAtMs: Int, gateSource: String?
    ) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.environment = environment
        self.workingDir = workingDir
        self.prompt = prompt
        self.appendSystemPrompt = appendSystemPrompt
        self.cadence = cadence
        self.timezone = timezone
        self.hasGate = hasGate
        self.gateRuntime = gateRuntime
        self.gateTimeoutSeconds = gateTimeoutSeconds
        self.sessionPolicy = sessionPolicy
        self.sessionId = sessionId
        self.quietPeriodMinutes = quietPeriodMinutes
        self.autocompactTokens = autocompactTokens
        self.model = model
        self.maxRuntimeMinutes = maxRuntimeMinutes
        self.maxTokenBudget = maxTokenBudget
        self.compactionThresholdTokens = compactionThresholdTokens
        self.sessionUsageGatePercent = sessionUsageGatePercent
        self.weeklyUsageGatePercent = weeklyUsageGatePercent
        self.notifyOnGateSkip = notifyOnGateSkip
        self.supervisionEnabled = supervisionEnabled
        self.supervisionModel = supervisionModel
        self.supervisionAppendPrompt = supervisionAppendPrompt
        self.supervisionCompactionThresholdTokens = supervisionCompactionThresholdTokens
        self.supervisionChunkIntervalSeconds = supervisionChunkIntervalSeconds
        self.supervisionChunkTokenThreshold = supervisionChunkTokenThreshold
        self.notifyPolicy = notifyPolicy
        self.urgent = urgent
        self.hasWebhook = hasWebhook
        self.stopped = stopped
        self.stoppedReason = stoppedReason
        self.lastFireAtMs = lastFireAtMs
        self.lastSuccessAtMs = lastSuccessAtMs
        self.nextFireAtMs = nextFireAtMs
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
        self.gateSource = gateSource
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, environment, prompt, cadence, timezone, urgent, stopped, model
        case workingDir = "working_dir"
        case appendSystemPrompt = "append_system_prompt"
        case hasGate = "has_gate"
        case gateRuntime = "gate_runtime"
        case gateTimeoutSeconds = "gate_timeout_seconds"
        case sessionPolicy = "session_policy"
        case sessionId = "session_id"
        case quietPeriodMinutes = "quiet_period_minutes"
        case autocompactTokens = "autocompact_tokens"
        case maxRuntimeMinutes = "max_runtime_minutes"
        case maxTokenBudget = "max_token_budget"
        case compactionThresholdTokens = "compaction_threshold_tokens"
        case sessionUsageGatePercent = "session_usage_gate_percent"
        case weeklyUsageGatePercent = "weekly_usage_gate_percent"
        case notifyOnGateSkip = "notify_on_gate_skip"
        case supervisionEnabled = "supervision_enabled"
        case supervisionModel = "supervision_model"
        case supervisionAppendPrompt = "supervision_append_prompt"
        case supervisionCompactionThresholdTokens = "supervision_compaction_threshold_tokens"
        case supervisionChunkIntervalSeconds = "supervision_chunk_interval_seconds"
        case supervisionChunkTokenThreshold = "supervision_chunk_token_threshold"
        case notifyPolicy = "notify_policy"
        case hasWebhook = "has_webhook"
        case stoppedReason = "stopped_reason"
        case lastFireAtMs = "last_fire_at_ms"
        case lastSuccessAtMs = "last_success_at_ms"
        case nextFireAtMs = "next_fire_at_ms"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
        case gateSource = "gate_source"
    }
}

/// `GET /api/scheduler/tasks/{id}/runs` — one fire, recorded at FIRE time rather than when a
/// session is created, so a fire that never reached a session still leaves a row. An empty
/// history would otherwise never prove a task did not fire.
public struct TaskRun: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let taskId: String
    public let trigger: TaskRunTrigger
    public let disposition: TaskRunDisposition
    /// Why, for every disposition that is not a plain fire.
    public let reason: String?
    public let resultStatus: TaskResultStatus?
    public let resultTitle: String?
    public let resultBody: String?
    public let sessionId: String?
    public let gateStdout: String?
    public let gateExitCode: Int?
    public let notified: Bool
    public let startedAtMs: Int
    public let finishedAtMs: Int?

    public init(
        id: String, taskId: String, trigger: TaskRunTrigger, disposition: TaskRunDisposition,
        reason: String?, resultStatus: TaskResultStatus?, resultTitle: String?,
        resultBody: String?, sessionId: String?, gateStdout: String?, gateExitCode: Int?,
        notified: Bool, startedAtMs: Int, finishedAtMs: Int?
    ) {
        self.id = id
        self.taskId = taskId
        self.trigger = trigger
        self.disposition = disposition
        self.reason = reason
        self.resultStatus = resultStatus
        self.resultTitle = resultTitle
        self.resultBody = resultBody
        self.sessionId = sessionId
        self.gateStdout = gateStdout
        self.gateExitCode = gateExitCode
        self.notified = notified
        self.startedAtMs = startedAtMs
        self.finishedAtMs = finishedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id, trigger, disposition, reason, notified
        case taskId = "task_id"
        case resultStatus = "result_status"
        case resultTitle = "result_title"
        case resultBody = "result_body"
        case sessionId = "session_id"
        case gateStdout = "gate_stdout"
        case gateExitCode = "gate_exit_code"
        case startedAtMs = "started_at_ms"
        case finishedAtMs = "finished_at_ms"
    }
}

/// One verdict from the supervisor watching a run.
public struct SupervisionVerdict: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let supervisionId: String
    public let verdict: SupervisionVerdictValue
    public let reason: String?
    public let fromMessageId: Int?
    public let toMessageId: Int?
    public let tokens: Int?
    public let createdAtMs: Int

    public init(
        id: String, supervisionId: String, verdict: SupervisionVerdictValue, reason: String?,
        fromMessageId: Int?, toMessageId: Int?, tokens: Int?, createdAtMs: Int
    ) {
        self.id = id
        self.supervisionId = supervisionId
        self.verdict = verdict
        self.reason = reason
        self.fromMessageId = fromMessageId
        self.toMessageId = toMessageId
        self.tokens = tokens
        self.createdAtMs = createdAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id, verdict, reason, tokens
        case supervisionId = "supervision_id"
        case fromMessageId = "from_message_id"
        case toMessageId = "to_message_id"
        case createdAtMs = "created_at_ms"
    }
}

/// The binding between a worker session and its supervisor.
///
/// `state` is the ONE authority on whether the worker may be resumed: `.stopped` is terminal,
/// and the resume path reads it here rather than from a second flag on the session row.
public struct Supervision: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let workerSessionId: String
    public let taskId: String?
    public let state: SupervisionState
    public let memo: String?
    public let cursorMessageId: Int?
    /// This attach's own configuration — set once at attach time, from a scheduled task's
    /// `supervision*` fields or from the session-menu configuration UI, and independent of any
    /// task afterwards. Absent on a backend that predates it.
    public let model: String?
    public let appendPrompt: String?
    /// Above this, the supervisor's own conversation is rotated to a fresh thread — never the
    /// worker's, which has no compaction setting here.
    public let compactionThresholdTokens: Int?
    /// How often the worker's transcript is flushed to the supervisor.
    public let chunkIntervalSeconds: Int?
    /// The token size of accumulated worker output that forces an early flush regardless of
    /// the interval above.
    public let chunkTokenThreshold: Int?
    public let createdAtMs: Int
    public let updatedAtMs: Int

    public init(
        id: String, workerSessionId: String, taskId: String?, state: SupervisionState,
        memo: String?, cursorMessageId: Int?, model: String? = nil, appendPrompt: String? = nil,
        compactionThresholdTokens: Int? = nil, chunkIntervalSeconds: Int? = nil,
        chunkTokenThreshold: Int? = nil, createdAtMs: Int, updatedAtMs: Int
    ) {
        self.id = id
        self.workerSessionId = workerSessionId
        self.taskId = taskId
        self.state = state
        self.memo = memo
        self.cursorMessageId = cursorMessageId
        self.model = model
        self.appendPrompt = appendPrompt
        self.compactionThresholdTokens = compactionThresholdTokens
        self.chunkIntervalSeconds = chunkIntervalSeconds
        self.chunkTokenThreshold = chunkTokenThreshold
        self.createdAtMs = createdAtMs
        self.updatedAtMs = updatedAtMs
    }

    enum CodingKeys: String, CodingKey {
        case id, state, memo, model
        case workerSessionId = "worker_session_id"
        case taskId = "task_id"
        case cursorMessageId = "cursor_message_id"
        case appendPrompt = "append_prompt"
        case compactionThresholdTokens = "compaction_threshold_tokens"
        case chunkIntervalSeconds = "chunk_interval_seconds"
        case chunkTokenThreshold = "chunk_token_threshold"
        case createdAtMs = "created_at_ms"
        case updatedAtMs = "updated_at_ms"
    }
}
