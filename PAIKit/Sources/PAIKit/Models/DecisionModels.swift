import Foundation

// Mirrors `Decision` and friends in pai-cloud's web/src/api/types.ts (`DecisionWire` in wire.py).

/// Where a decision stands. An unknown value decodes, so a build older than the backend survives
/// a state added later (it is just not open).
public enum DecisionState: Sendable, Hashable {
    case open, answered, withdrawn
    case unrecognized(String)
}

extension DecisionState: Codable {
    private static let knownValues: [String: DecisionState] = [
        "open": .open, "answered": .answered, "withdrawn": .withdrawn,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .open: try container.encode("open")
        case .answered: try container.encode("answered")
        case .withdrawn: try container.encode("withdrawn")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// A question an agent put to the owner: numbered `D<n>` per session, open until answered or
/// withdrawn.
public struct Decision: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let sessionId: String
    /// The session's title when the cross-session listing joined it.
    public let sessionTitle: String?
    public let number: Int
    /// What a yes sets in motion.
    public let title: String
    /// Short markdown: what it is and what each answer changes.
    public let context: String
    public let recommendation: String
    /// The answers offered as buttons; a free-text answer is always possible.
    public let options: [String]
    /// The agent's work waits for the answer.
    public let blocks: Bool
    public let state: DecisionState
    public let answer: String?
    public let createdAt: String
    /// Kept as received: an answer names it back so the server can refuse one given to a
    /// decision that changed since it was shown.
    public let updatedAt: String
    public let resolvedAt: String?

    enum CodingKeys: String, CodingKey {
        case id, number, title, context, recommendation, options, blocks, state, answer
        case sessionId = "session_id"
        case sessionTitle = "session_title"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case resolvedAt = "resolved_at"
    }

    public init(
        id: String, sessionId: String, sessionTitle: String? = nil, number: Int, title: String,
        context: String = "", recommendation: String, options: [String] = ["yes", "no"], blocks: Bool = false,
        state: DecisionState = .open, answer: String? = nil, createdAt: String = "", updatedAt: String = "",
        resolvedAt: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.number = number
        self.title = title
        self.context = context
        self.recommendation = recommendation
        self.options = options
        self.blocks = blocks
        self.state = state
        self.answer = answer
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.resolvedAt = resolvedAt
    }

    /// Whether `option` is the recommendation, ignoring case and surrounding space.
    public func isRecommended(_ option: String) -> Bool {
        option.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            == recommendation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// `GET /api/decisions`
public struct OpenDecisionsResponse: Codable, Sendable, Equatable {
    public let decisions: [Decision]

    public init(decisions: [Decision]) {
        self.decisions = decisions
    }
}

/// One answer of `POST /api/session/{id}/decisions/answer`.
public struct DecisionAnswer: Codable, Sendable, Equatable {
    public let number: Int
    public let answer: String
    /// The decision's `updatedAt` as it was shown; the server answers 409 when it moved on.
    public let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case number, answer
        case updatedAt = "updated_at"
    }

    public init(number: Int, answer: String, updatedAt: String? = nil) {
        self.number = number
        self.answer = answer
        self.updatedAt = updatedAt
    }
}

public struct AnswerDecisionsResponse: Codable, Sendable, Equatable {
    public let status: String
    /// The one message the answers became, as the session received it.
    public let message: String
    public let duplicate: Bool
    public let answered: [Decision]

    public init(status: String = "accepted", message: String, duplicate: Bool = false, answered: [Decision]) {
        self.status = status
        self.message = message
        self.duplicate = duplicate
        self.answered = answered
    }
}
