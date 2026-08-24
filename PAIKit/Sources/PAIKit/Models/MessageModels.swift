import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` (the "Message" section).

/// Arbitrary JSON, for the two places the API's shape is intentionally open: a tool call's
/// `input` (whatever shape that tool defines) and a token-usage payload Anthropic may add
/// fields to over time. Decoded directly as `[String: PaiJSONValue]` — never through a keyed
/// container with `CodingKeys` — so nested key names are preserved byte-for-byte rather than
/// risking a key-transform strategy silently renaming someone else's field.
public indirect enum PaiJSONValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PaiJSONValue])
    case array([PaiJSONValue])
    case null
}

extension PaiJSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: PaiJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([PaiJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case let .bool(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        }
    }
}

public enum MessageType: String, Codable, Sendable, Equatable {
    case user
    case assistant
    case toolResult = "tool_result"
    case system
}

public struct ToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let input: [String: PaiJSONValue]

    public init(id: String, name: String, input: [String: PaiJSONValue]) {
        self.id = id
        self.name = name
        self.input = input
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public let toolUseId: String
    public let toolName: String
    public let content: String
    public let isError: Bool

    enum CodingKeys: String, CodingKey {
        case toolUseId = "tool_use_id"
        case toolName = "tool_name"
        case content
        case isError = "is_error"
    }

    public init(toolUseId: String, toolName: String, content: String, isError: Bool) {
        self.toolUseId = toolUseId
        self.toolName = toolName
        self.content = content
        self.isError = isError
    }
}

public struct HookSummary: Codable, Sendable, Equatable {
    public let hookNames: [String]
    public let hasErrors: Bool
    public let errors: [String]
    public let preventedContinuation: Bool

    enum CodingKeys: String, CodingKey {
        case hookNames = "hook_names"
        case hasErrors = "has_errors"
        case errors
        case preventedContinuation = "prevented_continuation"
    }

    public init(hookNames: [String], hasErrors: Bool, errors: [String], preventedContinuation: Bool) {
        self.hookNames = hookNames
        self.hasErrors = hasErrors
        self.errors = errors
        self.preventedContinuation = preventedContinuation
    }
}

/// Token counts reported per message. Modelled as a raw key/value bag rather than four named
/// optionals plus a lost remainder, since the TS type's `[key: string]: unknown` index
/// signature says the API may report additional fields beyond the four Anthropic documents
/// today, and nothing here should have to change if it adds one.
public struct TokenUsage: Sendable, Equatable {
    public let values: [String: PaiJSONValue]

    public init(values: [String: PaiJSONValue]) {
        self.values = values
    }

    private func intValue(_ key: String) -> Int? {
        if case let .number(number)? = values[key] { return Int(number) }
        return nil
    }

    public var inputTokens: Int? { intValue("input_tokens") }
    public var outputTokens: Int? { intValue("output_tokens") }
    public var cacheCreationInputTokens: Int? { intValue("cache_creation_input_tokens") }
    public var cacheReadInputTokens: Int? { intValue("cache_read_input_tokens") }
}

extension TokenUsage: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        values = try container.decode([String: PaiJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

public struct Message: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let sessionId: String
    public let type: MessageType
    public let subtype: String?
    public let timestamp: String?
    public let content: String?
    public let thinking: String?
    public let toolCalls: [ToolCall]?
    public let toolResult: ToolResult?
    public let hookSummary: HookSummary?
    public let tokens: TokenUsage?
    public let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case type, subtype, timestamp, content, thinking
        case toolCalls = "tool_calls"
        case toolResult = "tool_result"
        case hookSummary = "hook_summary"
        case tokens
        case createdAt = "created_at"
    }

    public init(
        id: Int,
        sessionId: String,
        type: MessageType,
        subtype: String?,
        timestamp: String?,
        content: String?,
        thinking: String?,
        toolCalls: [ToolCall]?,
        toolResult: ToolResult?,
        hookSummary: HookSummary?,
        tokens: TokenUsage?,
        createdAt: String?
    ) {
        self.id = id
        self.sessionId = sessionId
        self.type = type
        self.subtype = subtype
        self.timestamp = timestamp
        self.content = content
        self.thinking = thinking
        self.toolCalls = toolCalls
        self.toolResult = toolResult
        self.hookSummary = hookSummary
        self.tokens = tokens
        self.createdAt = createdAt
    }
}
