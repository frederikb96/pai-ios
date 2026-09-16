import Foundation

/// The configured phrase for every command, plus the built-in variants recognized alongside it.
/// What `CommandPhrasesStore` persists and `CommandGrammar` matches against.
public struct CommandPhraseSet: Sendable, Equatable {
    /// The phrase shown and edited in Settings — always present for every `CommandKind`, so a
    /// lookup here is never optional at the call site.
    public var phrases: [CommandKind: String]

    public init(phrases: [CommandKind: String]) {
        self.phrases = phrases
    }

    /// A rare first word plus a pause before it is what the on-device models pick up reliably in
    /// both German and English — "Kai" is a German name and an English syllable either way,
    /// which is why it is the shared first word rather than "computer" (collides with ordinary
    /// dictation) or a fully separate phrase per language.
    public static let defaults = CommandPhraseSet(phrases: [
        .start: "Kai start",
        .stop: "Kai stop",
        .skip: "Kai skip",
        .mute: "Kai mute",
        .unmute: "Kai unmute",
        .end: "Kai end",
    ])

    /// Recognized alongside whatever `phrases` holds — never shown as the editable value, and
    /// never replaced by an edit to it. German inflections of the same defaults: "starte" and
    /// "stopp" are the imperative/past forms of start/stop, and "weiter" ("carry on") is the
    /// natural German way to ask for the mic back rather than a literal translation of "unmute".
    static let builtInVariants: [CommandKind: [String]] = [
        .start: ["Kai starte"],
        .stop: ["Kai stopp"],
        .unmute: ["Kai weiter"],
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
