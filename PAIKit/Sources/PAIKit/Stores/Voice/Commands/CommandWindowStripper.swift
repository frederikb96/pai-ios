import Foundation

/// Cuts a recognized command's spoken words out of the assembled transcript, so "Kai stop" never
/// lands in the message that gets sent. The offline engine owns command recognition end to end —
/// ElevenLabs' words are only the text this strips them out of, by time window plus a text match,
/// never by re-running the grammar against ElevenLabs' own transcript (its socket is exactly what
/// may be down at the moment a command matters most).
public enum CommandWindowStripper {
    /// How far, in either direction, a word may sit from a recognized command's `atOffset` and
    /// still be considered part of that spoken command rather than separately-dictated text
    /// nearby it.
    public static let windowSeconds: TimeInterval = 1

    /// `words` in take-offset order, `commands` the events fired for this take (any order).
    /// Every word inside a command's time window *and* matching that command's own vocabulary is
    /// dropped; everything else passes through unchanged, joined by a single space. The text
    /// match is what keeps a coincidental "stop" spoken elsewhere in the same second from being
    /// silently deleted along with a real command.
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
    /// built once per call rather than once per word.
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
        let normalized = CommandGrammar.normalize(word.text)
        guard !normalized.isEmpty else { return false }
        return commands.contains { command in
            guard vocabulary[command.kind]?.contains(normalized) == true else { return false }
            let window = (command.atOffset - windowSamples)...(command.atOffset + windowSamples)
            return window.overlaps(word.range)
        }
    }
}
