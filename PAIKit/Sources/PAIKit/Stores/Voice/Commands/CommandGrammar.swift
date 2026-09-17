import Foundation

/// Every phrase `CommandGrammar` matches text against — the transcript-recognition path for
/// every command but `.start`, and stripping a recognised command's own words back out of a sent
/// transcript. Fixed, never edited by Freddy: a full spoken phrase, not a single word, is what
/// makes "computer" safe to use at all — "computer send the message" is specific enough that
/// ordinary dictation about computers essentially never produces it by accident, unlike a bare
/// wake word would.
public struct CommandPhraseSet: Sendable, Equatable {
    /// Present for every `CommandKind`, so a lookup here is never optional at the call site.
    /// `.start` carries a phrase too even though it is only ever detected offline: it is what a
    /// stray "computer start the message" said while already recording is matched against, so the
    /// existing applicability gate (only meaningful in wake mode) is what silently ignores it,
    /// rather than a second special case.
    public var phrases: [CommandKind: String]

    public init(phrases: [CommandKind: String]) {
        self.phrases = phrases
    }

    public static let defaults = CommandPhraseSet(phrases: [
        .start: "computer start the message",
        .stop: "computer stop the message",
        .send: "computer send the message",
        .skip: "computer skip the message",
        .end: "computer end the call",
        .interruptOn: "computer interrupt on",
        .interruptOff: "computer interrupt off",
    ])

    /// Verb inflections tolerated for the "start"/"stop"/"send"/"skip" family, alongside each
    /// kind's own base verb — dictation rarely comes back in the exact base form every time
    /// ("sent the message" for a "send" spoken a beat late is ordinary, not a misfire), and
    /// tolerating it here is far cheaper than training around it.
    private static let messageVerbInflections: [CommandKind: [String]] = [
        .start: ["started"],
        .stop: ["stopped"],
        .send: ["sent", "sends"],
        .skip: ["skipped"],
    ]
    /// `nil` stands for no article at all — "computer send message" is as natural as "computer
    /// send the message".
    private static let articles: [String?] = ["the", "a", nil]

    /// Every "computer <verb> <article> message" combination for `kind`'s own verb family,
    /// derived from `basePhrase`'s own verb (its second word) rather than a hardcoded one, so a
    /// phrase set that overrides the base phrase carries its variants with it rather than a test
    /// override leaving the *default* verb's variants still matching underneath it. Includes the
    /// base form itself — a harmless duplicate of `basePhrase`, never a second distinct match.
    private static func messageCommandVariants(for kind: CommandKind, basePhrase: String) -> [String] {
        guard let base = basePhrase.split(separator: " ").dropFirst().first else { return [] }
        let verbs = [String(base)] + (messageVerbInflections[kind] ?? [])
        return verbs.flatMap { verb in
            articles.map { article in ["computer", verb, article, "message"].compactMap { $0 }.joined(separator: " ") }
        }
    }

    /// Every "computer <verb> <article> <call/message>" combination "end" accepts — "ended",
    /// "the"/"a"/no article, and either object, since Freddy says both. The verb itself is
    /// likewise derived from `basePhrase`'s own second word.
    private static func endVariants(basePhrase: String) -> [String] {
        guard let base = basePhrase.split(separator: " ").dropFirst().first else { return [] }
        let verbs = [String(base), "\(base)ed"]
        let objects = ["call", "message"]
        return verbs.flatMap { verb in
            objects.flatMap { object in
                articles.map { article in ["computer", verb, article, object].compactMap { $0 }.joined(separator: " ") }
            }
        }
    }

    /// Every variant `kind`'s own configured phrase gets, computed from that phrase rather than
    /// a fixed default — `allPhrases(for:)`'s own private half.
    private func variants(for kind: CommandKind) -> [String] {
        guard let basePhrase = phrases[kind], !basePhrase.isEmpty else { return [] }
        switch kind {
        case .start, .stop, .send, .skip: return Self.messageCommandVariants(for: kind, basePhrase: basePhrase)
        case .end: return Self.endVariants(basePhrase: basePhrase)
        case .interruptOn, .interruptOff: return []
        }
    }

    /// Every string recognized for `kind` — the configured phrase first, then its variants,
    /// deduplicated: a variant that happens to equal the base phrase itself is never a second,
    /// distinct entry — `CommandGrammar.matches` would otherwise report the identical match twice.
    public func allPhrases(for kind: CommandKind) -> [String] {
        var seen = Set<String>()
        var result = [String]()
        for phrase in [phrases[kind]].compactMap({ $0 }) + variants(for: kind) where !phrase.isEmpty {
            guard seen.insert(phrase).inserted else { continue }
            result.append(phrase)
        }
        return result
    }
}

/// Matches configured command phrases inside whatever text the offline engine produced.
/// Normalization and matching only — the position gate ("nothing spoken after it") is
/// `CommandDetector`'s, one layer up, since it needs more of `CommandObservation` than a plain
/// string.
public enum CommandGrammar {
    /// Case- and diacritic-insensitive, punctuation dropped (Western and CJK alike — the filter
    /// is a whitelist of alphanumerics, not a blocklist of specific marks), internal whitespace
    /// collapsed — so "Computer, send the message.", "COMPUTER SEND THE MESSAGE" and a
    /// transcript that renders its own full stop as "。" all match the same phrase.
    /// Preserves word boundaries 1:1 with the input (only ever removes or collapses whitespace,
    /// never merges two words into one) — `CommandDetector`'s stripping depends on that to line a
    /// match's word range up against `CommandObservation.wordTimes`.
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

    /// Every phrase from `phraseSet` found in `text`, matched whitespace-word-bounded so
    /// "computer" inside "computerized" never matches, in the order they occur. Overlapping
    /// matches of different commands are both reported; `CommandDetector` decides which one wins.
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
