import Foundation

/// Cuts a recognized command's spoken words out of the assembled transcript, so "computer send
/// the message" never lands in the message that gets sent.
public enum CommandWindowStripper {
    /// The fallback window, in either direction from a command's `atOffset`, used only when no
    /// `phraseRange` is available — a transcript match whose word timing didn't line up, or an
    /// older segment with no per-word timestamps at all. Sized for the longest phrase ("computer
    /// send the message", four words) at a slow, deliberate speaking pace; the ordinary case never
    /// reaches this at all; see `strip(words:commands:phraseSet:sampleRate:)`.
    public static let windowSeconds: TimeInterval = 2

    /// `words` in take-offset order, `commands` the events fired for this take (any order). A
    /// command with a `phraseRange` drops exactly the words that fall inside it — the matched
    /// phrase's own span, computed once by `CommandDetector` from the same word timing the
    /// transcript itself carries, so a generic word the phrase happens to share with ordinary
    /// dictation elsewhere ("the", "message") is never touched. A command with no `phraseRange`
    /// falls back to the old text-match-plus-time-window heuristic. Everything else passes through
    /// unchanged, joined by a single space.
    public static func strip(words: [Word], commands: [CommandEvent], phraseSet: CommandPhraseSet, sampleRate: Double)
        -> String
    {
        guard !commands.isEmpty else { return words.map(\.text).joined(separator: " ") }
        let windowSamples = Int(sampleRate * windowSeconds)
        let vocabulary = commandVocabulary(phraseSet: phraseSet)

        return words.filter {
            !isCommandWord($0, commands: commands, vocabulary: vocabulary, windowSamples: windowSamples)
        }
        .map(\.text).joined(separator: " ")
    }

    /// Every normalized word that appears in any configured phrase or variant, per command —
    /// built once per call rather than once per word. Only ever consulted for the fallback path.
    private static func commandVocabulary(phraseSet: CommandPhraseSet) -> [CommandKind: Set<String>] {
        Dictionary(
            uniqueKeysWithValues: CommandKind.allCases.map { kind in
                let words = phraseSet.allPhrases(for: kind).flatMap {
                    CommandGrammar.normalize($0).split(separator: " ").map(String.init)
                }
                return (kind, Set(words))
            })
    }

    private static func isCommandWord(
        _ word: Word, commands: [CommandEvent], vocabulary: [CommandKind: Set<String>], windowSamples: Int
    ) -> Bool {
        commands.contains { command in
            if let phraseRange = command.phraseRange {
                return phraseRange.overlaps(word.range)
            }
            let normalized = CommandGrammar.normalize(word.text)
            guard !normalized.isEmpty, vocabulary[command.kind]?.contains(normalized) == true else { return false }
            let window = (command.atOffset - windowSamples)...(command.atOffset + windowSamples)
            return window.overlaps(word.range)
        }
    }
}
