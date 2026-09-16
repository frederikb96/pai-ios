import Foundation

/// The six phrases the offline command engine owns end to end, never split between it and the
/// ElevenLabs transcript — in the situation this pipeline exists for, the socket carrying that
/// transcript is exactly the thing that may be down.
public enum CommandKind: String, Codable, Sendable, Equatable, CaseIterable {
    case start, stop, skip, mute, unmute, end
}

/// One result from whichever engine is listening — Apple's `SpeechAnalyzer` today, sherpa-onnx
/// keyword spotting if the device test says otherwise. `CommandDetector` is the only consumer;
/// which engine produced this observation is invisible to it.
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
