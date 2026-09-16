import Foundation

/// Turns the offline engine's raw ``CommandObservation``s into the rare, confident ``CommandEvent``
/// Freddy actually gets acted on — the gates that keep "so the agent thinks about computers all
/// day" from firing a command every few sentences.
///
/// Three gates, all documented at their point of use below: the **grammar** gate (a configured
/// phrase actually occurs), the **position** gate (nothing spoken after it — a command is never
/// found mid-sentence), and the **pause** gate (a beat of silence before it, when the engine can
/// supply word timing). A fourth rule is per-command rather than a gate: every command except
/// `skip` waits for a **final** result, since a false stop or mute is far more disruptive than a
/// half-second of extra latency; `skip` accepts a volatile (still-settling) result too, because a
/// false skip only costs one reply that can be asked for again.
public struct CommandDetector: Sendable {
    /// How much silence, in seconds, must sit between the words before a command phrase and the
    /// phrase itself for it to count as a deliberate command rather than a mention mid-sentence.
    /// Applied only when the observation actually carries word timing — see `passesPauseGate`.
    public static let defaultPauseGateSeconds: TimeInterval = 0.4

    private var phraseSet: CommandPhraseSet
    private let sampleRate: Double
    private let pauseGateSamples: Int
    /// The take offset of the last observation a command was actually fired from. An engine
    /// delivers a volatile result and then repeated, growing final results for the same stretch
    /// of speech; without this, the same spoken command would fire once per delivery instead of
    /// once per utterance.
    private var lastFiredOffset: Int = -1

    public init(
        phraseSet: CommandPhraseSet, sampleRate: Double,
        pauseGateSeconds: TimeInterval = CommandDetector.defaultPauseGateSeconds
    ) {
        self.phraseSet = phraseSet
        self.sampleRate = sampleRate
        self.pauseGateSamples = Int(sampleRate * pauseGateSeconds)
    }

    /// Freddy can change the phrases at any time; the detector picks up the new set on the next
    /// observation rather than needing to be rebuilt.
    public mutating func updatePhraseSet(_ phraseSet: CommandPhraseSet) {
        self.phraseSet = phraseSet
    }

    /// `nil` when nothing passed every gate — the overwhelmingly common case, since most
    /// observations contain no command phrase at all.
    public mutating func detect(_ observation: CommandObservation) -> CommandEvent? {
        guard observation.atOffset > lastFiredOffset else { return nil }
        let words = CommandGrammar.normalize(observation.text).split(separator: " ")
        guard let match = CommandGrammar.matches(in: observation.text, phraseSet: phraseSet).last else { return nil }

        // Position gate: the match must reach the last word of what has been recognized so far.
        // A phrase anywhere earlier was spoken *about*, not spoken *as* a command.
        guard match.range.upperBound == words.count else { return nil }

        // Final-vs-volatile policy: every command but `skip` waits for a final result.
        guard observation.isFinal || match.kind == .skip else { return nil }

        let pauseGate = passesPauseGate(match, observation: observation, wordCount: words.count)
        guard pauseGate.passed else { return nil }

        lastFiredOffset = observation.atOffset
        return CommandEvent(
            kind: match.kind, atOffset: observation.atOffset,
            confidence: confidence(isFinal: observation.isFinal, hadTiming: pauseGate.hadTiming))
    }

    /// `hadTiming` is `false` whenever the observation carries no word timing, or the timing
    /// doesn't line up with the text — the position gate is left to carry the whole judgement
    /// rather than refusing every command an engine without usable per-word timestamps could
    /// ever produce, and the phrase passes by default in that case.
    ///
    /// `wordTimes` is expected index-aligned with `CommandObservation.text`'s own whitespace
    /// split (not the normalized one) — `CommandGrammar.normalize` never merges or splits words,
    /// only trims and folds them, so the two splits agree on count whenever the engine's timing
    /// itself is trustworthy.
    private func passesPauseGate(_ match: CommandGrammar.Match, observation: CommandObservation, wordCount: Int)
        -> (passed: Bool, hadTiming: Bool)
    {
        guard match.range.lowerBound > 0 else {
            // The phrase opens the utterance: nothing precedes it to measure a pause against.
            return (true, false)
        }
        guard let wordTimes = observation.wordTimes else { return (true, false) }
        let rawWordCount = observation.text.split(separator: " ").count
        guard wordTimes.count == rawWordCount, rawWordCount == wordCount else { return (true, false) }

        let previousWordEnd = wordTimes[match.range.lowerBound - 1].upperBound
        let phraseStart = wordTimes[match.range.lowerBound].lowerBound
        return (phraseStart - previousWordEnd >= pauseGateSamples, true)
    }

    private func confidence(isFinal: Bool, hadTiming: Bool) -> Double {
        var value = isFinal ? 1.0 : 0.6
        if !hadTiming { value -= 0.2 }
        return max(0, min(1, value))
    }
}
