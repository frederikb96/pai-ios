import Foundation

/// What `GET /api/session-models` says: which `claude --model` aliases exist and the `claude
/// --effort` levels each accepts. The pickers read levels from here and never from a table of
/// their own.
public struct SessionModelCatalog: Sendable, Equatable {
    public var models: [SessionModelInfo]

    public init(models: [SessionModelInfo] = []) {
        self.models = models
    }

    public init(_ response: SessionModelsResponse) {
        self.init(models: response.models)
    }

    /// The thinking levels `model` accepts. Empty without a named model (which levels the plan's
    /// own model takes is unknown, and the server refuses a level there) and for a model that
    /// declares none.
    public func levels(for model: String?) -> [String] {
        guard let model else { return [] }
        return models.first { $0.id == model }?.effortLevels ?? []
    }

    /// `thinking` if `model` accepts it, otherwise `nil` — the server refuses a level the model
    /// does not take, and a level carried over from the previous model would otherwise sit in the
    /// form invisibly and fail the save.
    public func retainedThinking(_ thinking: String?, model: String?) -> String? {
        guard let thinking, levels(for: model).contains(thinking) else { return nil }
        return thinking
    }
}
