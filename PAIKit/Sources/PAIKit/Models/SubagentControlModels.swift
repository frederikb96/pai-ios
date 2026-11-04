import Foundation

/// What the backend says a viewer may do with one subagent, and what became of the messages sent
/// to it (`GET /api/session/{id}/subagent-controls`). Everything offered comes from here and is
/// never worked out on the client.
public struct SubagentControlsResponse: Decodable, Sendable, Equatable {
    public let controls: SubagentControls
    /// Oldest first, at most the last ten.
    public let nudges: [SubagentNudge]

    public init(controls: SubagentControls, nudges: [SubagentNudge]) {
        self.controls = controls
        self.nudges = nudges
    }
}

public struct SubagentControls: Decodable, Sendable, Equatable {
    public let canNudge: Bool
    public let canInterrupt: Bool
    /// False means an interrupt ends the agent for good; true means a later message resumes it.
    public let canResumeAfterInterrupt: Bool
    public let agentState: AgentState
    /// Why the composer is not offered, when it is not.
    public let reason: String?

    public init(
        canNudge: Bool, canInterrupt: Bool, canResumeAfterInterrupt: Bool, agentState: AgentState, reason: String?
    ) {
        self.canNudge = canNudge
        self.canInterrupt = canInterrupt
        self.canResumeAfterInterrupt = canResumeAfterInterrupt
        self.agentState = agentState
        self.reason = reason
    }

    /// A state this client does not know decodes to `.unrecognized` rather than failing the read.
    public enum AgentState: Sendable, Equatable {
        case running, idle, stopped, finished, unknown
        case unrecognized(String)
    }

    private enum CodingKeys: String, CodingKey {
        case canNudge = "can_nudge"
        case canInterrupt = "can_interrupt"
        case canResumeAfterInterrupt = "can_resume_after_interrupt"
        case agentState = "agent_state"
        case reason
    }
}

extension SubagentControls.AgentState: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "running": self = .running
        case "idle": self = .idle
        case "stopped": self = .stopped
        case "finished": self = .finished
        case "unknown": self = .unknown
        default: self = .unrecognized(raw)
        }
    }
}

/// One message sent to a subagent through its conversation, and how far it got.
public struct SubagentNudge: Decodable, Sendable, Equatable, Identifiable {
    public enum Delivery: Sendable, Equatable {
        case queued, relayed, delivered, failed, withdrawn
        case unrecognized(String)

        /// Still on its way, so the states are worth re-reading.
        public var isInFlight: Bool { self == .queued || self == .relayed }
    }

    public let id: String
    public let text: String
    public let state: Delivery
    public let error: String?
    /// The conversation passed it on in other words.
    public let reworded: Bool
    public let createdAt: String

    public init(id: String, text: String, state: Delivery, error: String?, reworded: Bool, createdAt: String) {
        self.id = id
        self.text = text
        self.state = state
        self.error = error
        self.reworded = reworded
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, state, error, reworded
        case createdAt = "created_at"
    }
}

extension SubagentNudge.Delivery: Decodable {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "queued": self = .queued
        case "relayed": self = .relayed
        case "delivered": self = .delivered
        case "failed": self = .failed
        case "withdrawn": self = .withdrawn
        default: self = .unrecognized(raw)
        }
    }
}

/// `POST /api/session/{id}/subagent-nudge`'s answer.
public struct SubagentNudgeResponse: Decodable, Sendable, Equatable {
    public let nudge: SubagentNudge
}

/// `POST /api/session/{id}/subagent-interrupt`'s answer.
public struct SubagentInterruptResponse: Decodable, Sendable, Equatable {
    public let stopped: Bool
    public let named: Bool
}
