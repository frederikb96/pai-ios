import Foundation

/// Turns the transcript's raw ``CommandObservation``s into the rare, confident ``CommandEvent``s
/// Freddy actually gets acted on — the gates that keep "so the agent thinks about computers all
/// day" from firing a command every few sentences.
///
/// Two gates, both documented at their point of use below: the **grammar** gate (a configured
/// phrase actually occurs) and the **position** gate (nothing spoken after it — a command is
/// never found mid-sentence). A full phrase like "computer send the message" is specific enough
/// on its own that no pause is needed before it to tell a deliberate command from a mention — a
/// bare wake word needed one, a four-word phrase does not. A third rule is per-command rather
/// than a gate: every command but `skip` waits for a **final** result, since a false stop or send
/// is far more disruptive than a half-second of extra latency; `skip` accepts a volatile
/// (still-settling) result too, because a false skip only costs one reply that can be asked for
/// again.
public struct CommandDetector: Sendable {
    private let phraseSet: CommandPhraseSet
    /// The last take offset a command was actually fired from. An engine delivers a volatile
    /// result and then repeated, growing final results for the same stretch of speech; without
    /// this, the same spoken command would fire once per delivery instead of once per utterance.
    private var lastFiredOffset: Int = -1

    public init(phraseSet: CommandPhraseSet, sampleRate: Double) {
        self.phraseSet = phraseSet
    }

    /// Commands said mid-dictation, where the talking carries straight on afterward rather than
    /// ending on them — too rare a phrase to need the position gate, and exempting it is what
    /// makes "computer interrupt on" reachable while still describing something else in the same
    /// breath.
    private static func isPositionGateExempt(_ kind: CommandKind) -> Bool {
        kind == .interruptOn || kind == .interruptOff
    }

    /// `.none` when nothing passed every gate — the overwhelmingly common case, since most
    /// observations contain no command phrase at all. `.rejected` is a phrase that was actually
    /// found but a gate turned away, worth its own diagnostics line since it is exactly the case
    /// that otherwise looks like the phrase was never heard at all.
    public mutating func detect(_ observation: CommandObservation) -> CommandDetectionOutcome {
        guard observation.atOffset > lastFiredOffset else { return .none }
        let words = CommandGrammar.normalize(observation.text).split(separator: " ")
        guard let match = CommandGrammar.matches(in: observation.text, phraseSet: phraseSet).last else { return .none }

        // Position gate: the match must reach the last word of what has been recognized so far.
        // A phrase anywhere earlier was spoken *about*, not spoken *as* a command.
        guard match.range.upperBound == words.count || Self.isPositionGateExempt(match.kind) else {
            return .rejected(kind: match.kind, reason: .position)
        }

        // Final-vs-volatile policy: every command but `skip` waits for a final result.
        guard observation.isFinal || match.kind == .skip else {
            return .rejected(kind: match.kind, reason: .notFinal)
        }

        lastFiredOffset = observation.atOffset
        return .accepted(
            CommandEvent(
                kind: match.kind, atOffset: phraseStart(match, observation: observation, wordCount: words.count),
                confidence: observation.isFinal ? 1.0 : 0.6,
                phraseRange: phraseRange(match, observation: observation, wordCount: words.count)))
    }

    /// `wordTimes` is expected index-aligned with `CommandObservation.text`'s own whitespace
    /// split (not the normalized one) — `CommandGrammar.normalize` never merges or splits words,
    /// only trims and folds them, so the two splits agree on count whenever the engine's timing
    /// itself is trustworthy. Both `phraseStart` and `phraseRange` below share this same
    /// alignment check, since neither means anything once it fails.
    private func timingIsUsable(_ observation: CommandObservation, wordCount: Int) -> [SampleRange]? {
        guard let wordTimes = observation.wordTimes else { return nil }
        let rawWordCount = observation.text.split(separator: " ").count
        guard wordTimes.count == rawWordCount, rawWordCount == wordCount else { return nil }
        return wordTimes
    }

    /// Where the phrase itself began, when word timing lines up with the text — otherwise the
    /// observation's own offset, which is where the observed text ends. A "stop" or "send" closes
    /// the turn at this offset, so stamping it earlier than the phrase would cut dictated words
    /// spoken in the same breath out of the message.
    private func phraseStart(_ match: CommandGrammar.Match, observation: CommandObservation, wordCount: Int) -> Int {
        guard let wordTimes = timingIsUsable(observation, wordCount: wordCount) else { return observation.atOffset }
        return wordTimes[match.range.lowerBound].lowerBound
    }

    /// The exact span the matched phrase's own words occupy, when word timing lines up — `nil`
    /// otherwise, which `CommandWindowStripper` degrades from gracefully.
    private func phraseRange(_ match: CommandGrammar.Match, observation: CommandObservation, wordCount: Int)
        -> SampleRange?
    {
        guard let wordTimes = timingIsUsable(observation, wordCount: wordCount) else { return nil }
        return wordTimes[match.range.lowerBound].lowerBound..<wordTimes[match.range.upperBound - 1].upperBound
    }
}
