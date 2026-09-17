import Foundation

/// Cuts a recognized command's spoken words out of the assembled transcript, so "computer send
/// the message" never lands in the message that gets sent.
public enum CommandWindowStripper {
    /// The fallback window, in either direction from a command's `atOffset`, used only for a
    /// `.transcript` command whose word timing didn't line up (a `phraseRange` could not be
    /// computed) — an older segment with no per-word timestamps at all, say. Sized for the longest
    /// phrase at a slow, deliberate speaking pace; the ordinary case never reaches this at all,
    /// since a transcript match almost always carries usable timing.
    public static let windowSeconds: TimeInterval = 2

    /// `words` in take-offset order, `commands` the events fired for this take (any order).
    ///
    /// - A `.manual` command has no spoken words at all — a button tap, never text — so it strips
    ///   nothing, ever. Applying the vocabulary-and-window fallback to one used to cut genuinely
    ///   dictated text near wherever the tap happened to land.
    /// - An offline `.start` is acoustic, not transcribed — there is no spoken phrase in the
    ///   transcript for *it*, but Freddy's own "computer" may still carry "start the message" (or
    ///   a mis-transcribed tail of it) into the very first words the newly-opened cycle
    ///   transcribes, since the engine fires the instant it hears "computer" and he may keep
    ///   talking through the rest. `offlineStartLeadingRun` strips exactly that leading run, never
    ///   anything deeper in — vocabulary membership plays no part in it.
    /// - A `.transcript` command with a `phraseRange` drops exactly the words inside it — the
    ///   matched phrase's own span, computed once by `CommandDetector` from the same word timing
    ///   the transcript itself carries, so a generic word the phrase happens to share with
    ///   ordinary dictation elsewhere ("the", "message") is never touched.
    /// - A `.transcript` command with no `phraseRange` falls back to the old text-match-plus-
    ///   time-window heuristic — the one case left where the exact words cannot be pinned down.
    ///
    /// Everything else passes through unchanged, joined by a single space.
    public static func strip(words: [Word], commands: [CommandEvent], phraseSet: CommandPhraseSet, sampleRate: Double)
        -> String
    {
        guard !commands.isEmpty else { return words.map(\.text).joined(separator: " ") }
        let windowSamples = Int(sampleRate * windowSeconds)
        let vocabulary = commandVocabulary(phraseSet: phraseSet)
        let leadingDrop = offlineStartLeadingRun(words: words, commands: commands)

        return words.enumerated()
            .filter { index, word in
                index >= leadingDrop
                    && !isCommandWord(word, commands: commands, vocabulary: vocabulary, windowSamples: windowSamples)
            }
            .map { $0.element.text }
            .joined(separator: " ")
    }

    /// How many of `words`' own leading elements are an offline "start" detection's own leading
    /// tail — a run from the very front of `words` that exactly matches "start the message", "the
    /// message", or "message" alone, checked only when `words` genuinely opens where the offline
    /// engine fired (its own first word does not precede the detection's own offset — otherwise
    /// this segment is not the new cycle's first, and nothing here is that leading run at all).
    /// Longest tail checked first, so "start the message" is not partially matched as just
    /// "message" starting two words in.
    private static func offlineStartLeadingRun(words: [Word], commands: [CommandEvent]) -> Int {
        guard let start = commands.first(where: { $0.kind == .start && $0.source == .offline }),
            let firstWord = words.first, firstWord.range.lowerBound >= start.atOffset
        else { return 0 }
        let tails: [[String]] = [["start", "the", "message"], ["the", "message"], ["message"]]
        for tail in tails {
            guard words.count >= tail.count else { continue }
            let candidate = words.prefix(tail.count).map { CommandGrammar.normalize($0.text) }
            if candidate.elementsEqual(tail) { return tail.count }
        }
        return 0
    }

    /// Never attributed to a command on their own — carrying zero discriminating power, an
    /// article inside the fallback's own ±2s window is exactly the "coincidental word nearby"
    /// case that window exists to avoid over-reaching into, now that the phrase variants
    /// (`CommandGrammar`) include "a"/"the" articles that would otherwise widen every command's
    /// vocabulary to match ordinary dictation.
    private static let genericVocabularyWords: Set<String> = ["a", "the"]

    /// Every normalized word that appears in any configured phrase or variant, per command, minus
    /// the generic articles above — built once per call rather than once per word. Only ever
    /// consulted for the `.transcript` no-`phraseRange` fallback path.
    private static func commandVocabulary(phraseSet: CommandPhraseSet) -> [CommandKind: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: CommandKind.allCases.map { kind in
                let words = phraseSet.allPhrases(for: kind).flatMap {
                    CommandGrammar.normalize($0).split(separator: " ").map(String.init)
                }
                return (kind, Set(words).subtracting(genericVocabularyWords))
            })
    }

    private static func isCommandWord(
        _ word: Word, commands: [CommandEvent], vocabulary: [CommandKind: Set<String>], windowSamples: Int
    ) -> Bool {
        commands.contains { command in
            guard command.source != .manual else { return false }
            if let phraseRange = command.phraseRange {
                return phraseRange.overlaps(word.range)
            }
            // An offline detection is handled entirely by `offlineStartLeadingRun` above — it has
            // no transcript vocabulary of its own to sweep a window over.
            guard command.source != .offline else { return false }
            let normalized = CommandGrammar.normalize(word.text)
            guard !normalized.isEmpty, vocabulary[command.kind]?.contains(normalized) == true else { return false }
            let window = (command.atOffset - windowSamples)...(command.atOffset + windowSamples)
            return window.overlaps(word.range)
        }
    }
}
