import Foundation
import Observation

/// The part of `GET /api/settings/llm` this app reads: what ultra-fast and fast sessions run on
/// when a session names nothing.
public struct SessionDefaults: Codable, Sendable, Equatable {
    public struct UltraFastModel: Codable, Sendable, Equatable {
        public let provider: String
        public let efforts: [String]

        public init(provider: String, efforts: [String]) {
            self.provider = provider
            self.efforts = efforts
        }
    }

    public struct UltraFast: Codable, Sendable, Equatable {
        public let model: String
        public let reasoningEffort: String
        public let models: [String: UltraFastModel]

        enum CodingKeys: String, CodingKey {
            case model
            case reasoningEffort = "reasoning_effort"
            case models
        }

        public init(model: String, reasoningEffort: String, models: [String: UltraFastModel]) {
            self.model = model
            self.reasoningEffort = reasoningEffort
            self.models = models
        }
    }

    public struct Fast: Codable, Sendable, Equatable {
        public let model: String
        public let thinking: String
        /// Each alias and the levels it accepts.
        public let models: [String: [String]]

        public init(model: String, thinking: String, models: [String: [String]]) {
            self.model = model
            self.thinking = thinking
            self.models = models
        }
    }

    public let ultrafast: UltraFast
    public let fast: Fast

    public init(ultrafast: UltraFast, fast: Fast) {
        self.ultrafast = ultrafast
        self.fast = fast
    }
}

/// A partial change; a field left `nil` is not sent.
public struct SessionDefaultsUpdate: Encodable, Sendable, Equatable {
    public var ultrafastModel: String?
    public var ultrafastReasoningEffort: String?
    public var fastModel: String?
    public var fastThinking: String?

    enum CodingKeys: String, CodingKey {
        case ultrafastModel = "ultrafast_model"
        case ultrafastReasoningEffort = "ultrafast_reasoning_effort"
        case fastModel = "fast_model"
        case fastThinking = "fast_thinking"
    }

    public init(
        ultrafastModel: String? = nil, ultrafastReasoningEffort: String? = nil,
        fastModel: String? = nil, fastThinking: String? = nil
    ) {
        self.ultrafastModel = ultrafastModel
        self.ultrafastReasoningEffort = ultrafastReasoningEffort
        self.fastModel = fastModel
        self.fastThinking = fastThinking
    }
}

/// What `SessionDefaultsStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol SessionDefaultsApiClient: Sendable {
    func getSessionDefaults() async throws -> SessionDefaults
    func updateSessionDefaults(_ update: SessionDefaultsUpdate) async throws -> SessionDefaults
}

extension PaiApiClient: SessionDefaultsApiClient {}

/// The ultra-fast and fast defaults, one backend row every client reads. A pick is saved at once,
/// and what shows afterwards is the server's answer.
@MainActor
@Observable
public final class SessionDefaultsStore {
    /// `nil` until the first load succeeds.
    public private(set) var defaults: SessionDefaults?
    public private(set) var isSaving = false
    public private(set) var errorMessage: String?

    private static let effortOrder = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
    private let api: any SessionDefaultsApiClient

    public init(api: any SessionDefaultsApiClient) {
        self.api = api
    }

    public func load() async {
        do {
            defaults = try await api.getSessionDefaults()
            errorMessage = nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load the session defaults"
        }
    }

    /// Claude models first, each provider's by id.
    public var ultrafastModelIds: [String] {
        (defaults?.ultrafast.models ?? [:])
            .sorted {
                let (lhs, rhs) = ($0.value.provider == "anthropic", $1.value.provider == "anthropic")
                return lhs == rhs ? $0.key < $1.key : lhs
            }
            .map(\.key)
    }

    public var ultrafastEfforts: [String] {
        guard let ultrafast = defaults?.ultrafast else { return [] }
        return Self.ordered(ultrafast.models[ultrafast.model]?.efforts ?? [])
    }

    public var fastModels: [String] {
        CreateSessionStore.modelOptions.compactMap(\.id).filter { defaults?.fast.models[$0] != nil }
    }

    public var fastLevels: [String] {
        guard let fast = defaults?.fast else { return [] }
        return fast.models[fast.model] ?? []
    }

    public func save(_ update: SessionDefaultsUpdate) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            defaults = try await api.updateSessionDefaults(update)
            errorMessage = nil
        } catch {
            let reason = (error as? PaiError)?.userMessage ?? "Could not reach the server"
            errorMessage = "Couldn't save: \(reason)"
        }
    }

    private static func ordered(_ levels: [String]) -> [String] {
        levels.sorted { (effortOrder.firstIndex(of: $0) ?? .max) < (effortOrder.firstIndex(of: $1) ?? .max) }
    }
}
