import Foundation

/// The five commands Freddy's chart defines. No mute: muting the outgoing audio is the app's own
/// affordance (the Action Button, a later block), never a spoken command. Each is either
/// recognised end to end by its own trained wake-word classifier (the offline engine) or, for
/// whichever commands aren't loaded offline, cut out of the ElevenLabs transcript by the same
/// text-matching gates that always applied — `WakeWordListeningConfig` decides which, per
/// command, as a setting rather than a second code path.
public enum CommandKind: String, Codable, Sendable, Equatable, CaseIterable {
    case start, stop, send, skip, end
    /// Toggles whether replies may interrupt recording. Recognised only from the recording's own
    /// transcript — no offline classifier is trained for it.
    case interrupt
}

extension CommandKind {
    /// The trained classifier's name, and the bundled `.onnx` file's name minus its extension —
    /// `WakeWordModel.loadModel(url:name:)` defaults to exactly this, so a classifier's own
    /// output dictionary (keyed by this same string) maps straight back to a `CommandKind` with
    /// nothing else to configure.
    public var modelName: String { "kai_\(rawValue)" }

    /// The inverse of `modelName` — `nil` for any name that isn't one of the five commands (a
    /// stray bundled file, or a model a future build trained that this one predates), so a
    /// caller degrades to "unrecognised model, ignore" rather than crashing on an unknown key.
    public init?(modelName: String) {
        guard modelName.hasPrefix("kai_") else { return nil }
        self.init(rawValue: String(modelName.dropFirst("kai_".count)))
    }
}

/// One result from whichever engine is listening for a command not loaded into the offline
/// wake-word engine — the ElevenLabs live transcript, while recording. `CommandDetector` is the
/// only consumer.
public struct CommandObservation: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    /// Take-offset ranges for each recognised word, when the engine can supply them — the
    /// position and pause gates need to know where in the take a phrase actually sat.
    public let wordTimes: [SampleRange]?
    public let atOffset: Int

    public init(text: String, isFinal: Bool, wordTimes: [SampleRange]? = nil, atOffset: Int) {
        self.text = text
        self.isFinal = isFinal
        self.wordTimes = wordTimes
        self.atOffset = atOffset
    }
}

/// A command `CommandDetector` accepted — past the grammar, the position gate and the pause gate.
public struct CommandEvent: Sendable, Equatable {
    public let kind: CommandKind
    public let atOffset: Int
    public let confidence: Double

    public init(kind: CommandKind, atOffset: Int, confidence: Double) {
        self.kind = kind
        self.atOffset = atOffset
        self.confidence = confidence
    }
}
