import Foundation

/// Every phrase `CommandGrammar` matches text against — the fallback recognition path for a
/// command not loaded into the offline wake-word engine, and stripping a recognised command's
/// own words back out of a sent transcript regardless of which path recognised it. Fixed, never
/// edited by Freddy: a trained classifier hears an acoustic phrase, not typed text, so `.defaults`
/// is what every caller actually uses; a custom `CommandPhraseSet` exists only for tests.
public struct CommandPhraseSet: Sendable, Equatable {
    /// Present for every `CommandKind`, so a lookup here is never optional at the call site.
    public var phrases: [CommandKind: String]

    public init(phrases: [CommandKind: String]) {
        self.phrases = phrases
    }

    /// A rare first word plus a pause before it is what a listener picks up reliably in both
    /// German and English — "Kai" is a German name and an English syllable either way, which is
    /// why it is the shared first word rather than "computer" (collides with ordinary dictation)
    /// or a fully separate phrase per language.
    public static let defaults = CommandPhraseSet(phrases: [
        .start: "Kai start",
        .stop: "Kai stop",
        .send: "Kai send",
        .skip: "Kai skip",
        .end: "Kai end",
        .interrupt: "Kai interrupt",
    ])

    /// Recognized alongside whatever `phrases` holds, never shown in place of it. German
    /// inflections of the same defaults: "starte" and "stopp" are the imperative/past forms of
    /// start/stop, common enough in ordinary German speech to need their own variant. "send",
    /// "skip" and "end" are loanwords already close enough to their German pronunciation not to
    /// need one.
    static let builtInVariants: [CommandKind: [String]] = [
        .start: ["Kai starte"],
        .stop: ["Kai stopp"],
    ]

    /// Every string recognized for `kind` — the configured phrase first, then its variants.
    public func allPhrases(for kind: CommandKind) -> [String] {
        var result = [String]()
        if let phrase = phrases[kind], !phrase.isEmpty { result.append(phrase) }
        result.append(contentsOf: Self.builtInVariants[kind] ?? [])
        return result
    }
}

/// Matches configured command phrases inside whatever text the offline engine produced.
/// Normalization and matching only — the position gate ("nothing spoken after it"), the pause
/// gate, and the final-vs-volatile policy are `CommandDetector`'s, one layer up, since they need
/// more of `CommandObservation` than a plain string.
public enum CommandGrammar {
    /// Case- and diacritic-insensitive, punctuation dropped, internal whitespace collapsed — so
    /// "Kai, stop!", "KAI STOP" and an autocorrected "Kaï stop" all match the same phrase.
    /// Preserves word boundaries 1:1 with the input (only ever removes or collapses whitespace,
    /// never merges two words into one) — `CommandDetector`'s pause gate depends on that to line
    /// a match's word range up against `CommandObservation.wordTimes`.
    public static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = String(
            folded.unicodeScalars.map { scalar in
                CharacterSet.alphanumerics.contains(scalar) || scalar == " " ? Character(scalar) : " "
            })
        return cleaned.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// One occurrence of a configured phrase inside a normalized text. `range` indexes the
    /// normalized text's whitespace-split words, not characters — the unit `CommandDetector`
    /// needs to line up against `CommandObservation.wordTimes`.
    public struct Match: Sendable, Equatable {
        public let kind: CommandKind
        public let range: Range<Int>
    }

    /// Every phrase from `phraseSet` found in `text`, matched whitespace-word-bounded so "Kai"
    /// inside "Kaiser" never matches, in the order they occur. Overlapping matches of different
    /// commands are both reported; `CommandDetector` decides which one wins.
    public static func matches(in text: String, phraseSet: CommandPhraseSet) -> [Match] {
        let words = normalize(text).split(separator: " ")
        guard !words.isEmpty else { return [] }

        var results: [Match] = []
        for kind in CommandKind.allCases {
            for phrase in phraseSet.allPhrases(for: kind) {
                let phraseWords = normalize(phrase).split(separator: " ")
                guard !phraseWords.isEmpty, phraseWords.count <= words.count else { continue }
                var start = 0
                while start + phraseWords.count <= words.count {
                    if words[start..<(start + phraseWords.count)].elementsEqual(phraseWords) {
                        results.append(Match(kind: kind, range: start..<(start + phraseWords.count)))
                        start += phraseWords.count
                    } else {
                        start += 1
                    }
                }
            }
        }
        return results.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
}
