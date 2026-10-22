import Foundation

/// Where one kind of alert goes: to the person (push and mail), to the scheduled task that
/// repairs PAI, or both. See `SessionStatus`'s doc comment for why `.unrecognized` exists rather
/// than a throwing decode.
public enum AlertRoute: Sendable, Hashable {
    case notify, agent, both
    case unrecognized(String)

    /// The three a picker offers, in display order.
    public static let choices: [AlertRoute] = [.notify, .agent, .both]

    public var label: String {
        switch self {
        case .notify: return "Me"
        case .agent: return "Agent"
        case .both: return "Both"
        case let .unrecognized(raw): return raw
        }
    }
}

extension AlertRoute: Codable {
    private static let knownValues: [String: AlertRoute] = [
        "notify": .notify, "agent": .agent, "both": .both,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .notify: try container.encode("notify")
        case .agent: try container.encode("agent")
        case .both: try container.encode("both")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// One family of alert keys that routing is set per. The server owns the list.
public struct AlertKindInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    /// Glob patterns over an alert's key; empty for the catch-all `other`.
    public let patterns: [String]

    public init(id: String, label: String, patterns: [String]) {
        self.id = id
        self.label = label
        self.patterns = patterns
    }
}

/// `GET/PUT /api/settings/alert-routing`.
public struct AlertRoutingSettings: Codable, Sendable, Equatable {
    /// Every kind, in the server's own order, `other` last.
    public let kinds: [AlertKindInfo]
    /// Only kinds routed away from `notify`; a kind absent here notifies.
    public let routes: [String: AlertRoute]
    public let agentTaskId: String?
    /// `nil` when no task is chosen or the chosen one no longer exists.
    public let agentTaskName: String?
    /// Why routing to the agent would fall back to notifying right now.
    public let agentTaskProblem: String?
    /// Kinds that wake a task of their own instead of the default one, by kind id.
    public let kindTasks: [String: String]
    /// Per kind in `kindTasks`, why its task cannot be woken right now.
    public let kindTaskProblems: [String: String]
    public let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case kinds, routes
        case agentTaskId = "agent_task_id"
        case agentTaskName = "agent_task_name"
        case agentTaskProblem = "agent_task_problem"
        case kindTasks = "kind_tasks"
        case kindTaskProblems = "kind_task_problems"
        case updatedAt = "updated_at"
    }

    public init(
        kinds: [AlertKindInfo], routes: [String: AlertRoute], agentTaskId: String?, agentTaskName: String?,
        agentTaskProblem: String?, kindTasks: [String: String], kindTaskProblems: [String: String],
        updatedAt: String
    ) {
        self.kinds = kinds
        self.routes = routes
        self.agentTaskId = agentTaskId
        self.agentTaskName = agentTaskName
        self.agentTaskProblem = agentTaskProblem
        self.kindTasks = kindTasks
        self.kindTaskProblems = kindTaskProblems
        self.updatedAt = updatedAt
    }
}

/// The whole routing map, the chosen task and the per-kind tasks. `agent_task_id` is always
/// written, `null` included: an omitted key would leave a cleared task chosen. `kind_tasks` is
/// always written too, `{}` included: the server keeps what is stored when the key is omitted.
public struct AlertRoutingUpdate: Encodable, Sendable, Equatable {
    public let routes: [String: AlertRoute]
    public let agentTaskId: String?
    public let kindTasks: [String: String]

    enum CodingKeys: String, CodingKey {
        case routes
        case agentTaskId = "agent_task_id"
        case kindTasks = "kind_tasks"
    }

    public init(routes: [String: AlertRoute], agentTaskId: String?, kindTasks: [String: String]) {
        self.routes = routes
        self.agentTaskId = agentTaskId
        self.kindTasks = kindTasks
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(routes, forKey: .routes)
        try container.encode(agentTaskId, forKey: .agentTaskId)
        try container.encode(kindTasks, forKey: .kindTasks)
    }
}
