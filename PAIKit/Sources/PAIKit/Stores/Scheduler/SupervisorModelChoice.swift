import Foundation

/// What `GET /api/session-models` says: which `claude --model` aliases exist, the `claude
/// --effort` levels each accepts, and the model a supervisor runs on when none is named. The
/// pickers read levels from here and never from a table of their own.
public struct SessionModelCatalog: Sendable, Equatable {
    public var models: [SessionModelInfo]
    public var supervisorDefaultModel: String?

    public init(models: [SessionModelInfo] = [], supervisorDefaultModel: String? = nil) {
        self.models = models
        self.supervisorDefaultModel = supervisorDefaultModel
    }

    public init(_ response: SessionModelsResponse) {
        self.init(models: response.models, supervisorDefaultModel: response.supervisorDefaultModel)
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

/// The supervisor model choices and the thinking rules that go with them, ported from the web's
/// `SupervisorConfigForm` and `ThinkingSelect`.
///
/// Stored `supervision_model` has three meanings: `nil` is the supervisor default (shown under the
/// model it currently is), `planDefault` is the plan's own model — a value of its own because `nil`
/// is taken — and anything else is a `claude --model` alias.
public enum SupervisorModelChoice {

    /// `pai_cloud.supervision.engine.SUPERVISOR_PLAN_DEFAULT`.
    public static let planDefault = "default"

    /// The picker's options in display order: Default (the plan's own), Haiku, Sonnet, then the
    /// rest, with the model that is currently the supervisor default carrying `nil` as its id and
    /// a "(supervisor default)" suffix. Without a known default model a plain "Supervisor default"
    /// option stands in for it.
    public static func options(defaultModel: String?) -> [(id: String?, label: String)] {
        var options: [(id: String?, label: String)] = [(planDefault, "Default")]
        for option in CreateSessionStore.modelOptions {
            guard let id = option.id else { continue }
            options.append(id == defaultModel ? (nil, "\(option.label) (supervisor default)") : (id, option.label))
        }
        if defaultModel == nil { options.append((nil, "Supervisor default")) }
        return options
    }

    /// The option to highlight: a stored value naming the supervisor default explicitly lights the
    /// same option as `nil`.
    public static func shownModel(stored: String?, defaultModel: String?) -> String? {
        if let stored, stored == defaultModel { return nil }
        return stored
    }

    /// The model the supervisor actually launches with, which decides the thinking levels on
    /// offer; the plan's own model has none.
    public static func launchedModel(stored: String?, defaultModel: String?) -> String? {
        stored == planDefault ? nil : (stored ?? defaultModel)
    }
}
