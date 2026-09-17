import Foundation

/// Every command call mode recognises. `.start` is reached only through the offline wake-word
/// engine — the paid transcript is never running in wake mode, so there is nothing for a
/// transcript-based grammar to match it against. Every other command is recognised from the
/// dictated text while recording, as a full spoken phrase (`CommandGrammar`/`CommandDetector`).
/// No mute: muting the outgoing audio is the app's own affordance (the Action Button), never a
/// spoken command.
public enum CommandKind: String, Codable, Sendable, Equatable, CaseIterable {
    case start, stop, send, skip, end
    /// Sets whether replies may interrupt recording, explicitly rather than toggling — recognised
    /// only from the recording's own transcript.
    case interruptOn, interruptOff
}

/// One result from the ElevenLabs live transcript, while recording — what `CommandDetector`
/// matches a configured phrase against.
public struct CommandObservation: Sendable, Equatable {
    public let text: String
    public let isFinal: Bool
    /// Take-offset ranges for each recognised word, when the engine can supply them — the
    /// position gate, and precise stripping of the matched phrase's own words, both need to know
    /// where in the take a phrase actually sat.
    public let wordTimes: [SampleRange]?
    /// Where the observed text ends in the take.
    public let atOffset: Int

    public init(text: String, isFinal: Bool, wordTimes: [SampleRange]? = nil, atOffset: Int) {
        self.text = text
        self.isFinal = isFinal
        self.wordTimes = wordTimes
        self.atOffset = atOffset
    }
}

/// A command `CommandDetector` accepted — past the grammar and the position gate — or a manual
/// tap or offline wake-word detection standing in for one.
public struct CommandEvent: Sendable, Equatable {
    public let kind: CommandKind
    public let atOffset: Int
    public let confidence: Double
    /// Exactly the take-offset span the matched phrase's own words occupied, when word timing was
    /// available to compute it — `nil` for a manual tap, an offline detection (no transcript
    /// words exist for those), or a transcript match whose timing didn't line up.
    /// `CommandWindowStripper` uses this to remove precisely the phrase's own words rather than
    /// approximating from a time window.
    public let phraseRange: SampleRange?

    public init(kind: CommandKind, atOffset: Int, confidence: Double, phraseRange: SampleRange? = nil) {
        self.kind = kind
        self.atOffset = atOffset
        self.confidence = confidence
        self.phraseRange = phraseRange
    }
}

/// Why a phrase `CommandDetector` found was not accepted — logged so a silent no-op on a real
/// device ("computer send the message" said, nothing happened) is diagnosable from the words
/// alone rather than guessed at.
public enum CommandRejectReason: String, Sendable, Equatable {
    case position = "not at the end of the utterance"
    case notFinal = "still volatile"
}

/// `CommandDetector.detect(_:)`'s result: nothing matched, a match was found but a gate rejected
/// it, or a command was accepted.
public enum CommandDetectionOutcome: Sendable, Equatable {
    case none
    case rejected(kind: CommandKind, reason: CommandRejectReason)
    case accepted(CommandEvent)
}
