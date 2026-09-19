import Foundation

/// Recognises "computer send the message" from the draft's own polled text while dictating —
/// the one spoken command a pre-session take must still catch even though it has no live
/// transcript feed of its own to run the full `CommandDetector` against (that detector needs
/// take-relative sample offsets and word timing, neither of which exists for text arriving
/// through a draft region poll rather than a realtime socket). Deliberately narrower than
/// `CommandDetector`: no pause gate (the whole text is already committed, never volatile, by the
/// time it reaches a draft region) and no other command — a hands-free take's only other way out
/// is the record button itself.
public enum SpokenSendCommand {
    /// `text` with the trailing "send" phrase removed, when the phrase actually closes it —
    /// `nil` otherwise, including when the phrase occurs but words follow it (the same position
    /// gate `CommandDetector` applies: spoken *about*, not spoken *as* a command).
    public static func strip(from text: String) -> String? {
        let words = CommandGrammar.normalize(text).split(separator: " ")
        guard !words.isEmpty else { return nil }
        let matches = CommandGrammar.matches(in: text, phraseSet: .defaults).filter { $0.kind == .send }
        guard let last = matches.last, last.range.upperBound == words.count else { return nil }

        // The phrase matched against the *normalized* text; removing it from the original means
        // dropping the same number of trailing normalized words' worth of raw text. Original
        // whitespace-split words are never merged or split by normalization
        // (`CommandGrammar.normalize`'s own contract), so the raw text's word count agrees with
        // the normalized one and the same trailing slice can be dropped from it directly.
        let rawWords = text.split(separator: " ", omittingEmptySubsequences: true)
        guard rawWords.count == words.count else { return nil }
        let remaining = rawWords[..<last.range.lowerBound]
        return remaining.joined(separator: " ")
    }
}
