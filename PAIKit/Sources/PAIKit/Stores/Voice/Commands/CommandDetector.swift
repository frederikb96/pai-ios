import Foundation

/// Turns the transcript's raw ``CommandObservation``s into the rare, confident ``CommandEvent``s
/// Freddy actually gets acted on — the gates that keep "so the agent thinks about computers all
/// day" from firing a command every few sentences.
///
/// Three gates, all documented at their point of use below: the **grammar** gate (a configured
/// phrase actually occurs), the **position** gate (nothing spoken after it — a command is never
/// found mid-sentence), and the **pause** gate (nothing spoken with no real gap right before it —
/// a full phrase like "computer send the message" is specific enough that no pause is needed to
/// tell a deliberate command from a mention *most* of the time, but "the problem is that when I
/// say computer quit the call" ends its own sentence on the phrase too, with nothing after it, so
/// the position gate alone lets it through). A fourth rule is per-command rather than a gate:
/// every command but `skip` waits for a **final** result, since a false stop or send is far more
/// disruptive than a half-second of extra latency; `skip` accepts a volatile (still-settling)
/// result too, because a false skip only costs one reply that can be asked for again.
public struct CommandDetector: Sendable {
    /// How much silence, in seconds, must sit between the words before a command phrase and the
    /// phrase itself for it to count as a deliberate command rather than a mention mid-sentence.
    /// Short, since the phrase itself already carries most of the specificity a bare wake word
    /// needed a longer pause to make up for — applied only when the observation actually carries
    /// word timing, and never when the phrase opens the observation (see `passesPauseGate`).
    public static let defaultPauseGateSeconds: TimeInterval = 0.25

    private let phraseSet: CommandPhraseSet
    private let pauseGateSamples: Int
    /// The last take offset a command was actually fired from. An engine delivers a volatile
    /// result and then repeated, growing final results for the same stretch of speech; without
    /// this, the same spoken command would fire once per delivery instead of once per utterance.
    private var lastFiredOffset: Int = -1

    public init(
        phraseSet: CommandPhraseSet, sampleRate: Double,
        pauseGateSeconds: TimeInterval = CommandDetector.defaultPauseGateSeconds
    ) {
        self.phraseSet = phraseSet
        self.pauseGateSamples = Int(sampleRate * pauseGateSeconds)
    }

    /// Commands said mid-dictation, where the talking carries straight on afterward rather than
    /// ending on them — too rare a phrase to need either the position or the pause gate, and
    /// exempting it is what makes "computer interrupt on" reachable while still describing
    /// something else in the same breath.
    private static func isGateExempt(_ kind: CommandKind) -> Bool {
        kind == .interruptOn || kind == .interruptOff
    }

    /// Empty when nothing passed every gate — the overwhelmingly common case, since most
    /// observations contain no command phrase at all. One entry per phrase `CommandGrammar` found
    /// in the observation, in the order they occur — "computer interrupt off computer send the
    /// message" is two commands in one utterance, and both are reported rather than only the
    /// last: `.interruptOff` is exempt from the position gate (said mid-dictation, so it is
    /// essentially never the last thing before a commit) while `.send` still needs to reach the
    /// end. A `.rejected` entry is a phrase that was actually found but a gate turned it away,
    /// worth its own diagnostics line since it is exactly the case that otherwise looks like the
    /// phrase was never heard at all.
    public mutating func detect(_ observation: CommandObservation) -> [CommandDetectionOutcome] {
        guard observation.atOffset > lastFiredOffset else { return [] }
        let words = CommandGrammar.normalize(observation.text).split(separator: " ")
        let matches = CommandGrammar.matches(in: observation.text, phraseSet: phraseSet)
        guard !matches.isEmpty else { return [] }

        var outcomes: [CommandDetectionOutcome] = []
        var anyAccepted = false
        for match in matches {
            // Position gate: a non-exempt match must reach the last word of what has been
            // recognized so far — anywhere earlier, it was spoken *about*, not spoken *as* a
            // command, unless nothing but another command phrase follows it.
            guard match.range.upperBound == words.count || Self.isGateExempt(match.kind) else {
                outcomes.append(.rejected(kind: match.kind, reason: .position))
                continue
            }
            guard
                passesPauseGate(match, observation: observation, wordCount: words.count)
                    || Self.isGateExempt(match.kind)
            else {
                outcomes.append(.rejected(kind: match.kind, reason: .pause))
                continue
            }
            // Final-vs-volatile policy: every command but `skip` waits for a final result.
            guard observation.isFinal || match.kind == .skip else {
                outcomes.append(.rejected(kind: match.kind, reason: .notFinal))
                continue
            }
            anyAccepted = true
            outcomes.append(
                .accepted(
                    CommandEvent(
                        kind: match.kind,
                        atOffset: phraseStart(match, observation: observation, wordCount: words.count),
                        confidence: observation.isFinal ? 1.0 : 0.6,
                        phraseRange: phraseRange(match, observation: observation, wordCount: words.count),
                        source: .transcript)))
        }
        if anyAccepted { lastFiredOffset = observation.atOffset }
        return outcomes
    }

    /// `true` when the phrase opens the observation — nothing precedes it *in this text* to
    /// measure a gap against at all, whether because it is a genuine committed-segment boundary
    /// (the transcription service's own pause detection, a signal independent of ours) or simply
    /// because there is no data here to check — both are treated the same: never reject for lack
    /// of information. Otherwise `true` only when real word timing shows at least
    /// `pauseGateSeconds` of silence before it; a phrase butting straight up against the words
    /// before it, with real timing to prove it, is what "I say computer quit the call" looks like.
    private func passesPauseGate(_ match: CommandGrammar.Match, observation: CommandObservation, wordCount: Int) -> Bool
    {
        guard match.range.lowerBound > 0 else { return true }
        guard let wordTimes = timingIsUsable(observation, wordCount: wordCount) else { return true }
        let previousWordEnd = wordTimes[match.range.lowerBound - 1].upperBound
        let phraseStart = wordTimes[match.range.lowerBound].lowerBound
        return phraseStart - previousWordEnd >= pauseGateSamples
    }

    /// `wordTimes` is expected index-aligned with `CommandObservation.text`'s own whitespace
    /// split (not the normalized one) — `CommandGrammar.normalize` never merges or splits words,
    /// only trims and folds them, so the two splits agree on count whenever the engine's timing
    /// itself is trustworthy. `passesPauseGate`, `phraseStart` and `phraseRange` below all share
    /// this same alignment check, since none of them mean anything once it fails.
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
