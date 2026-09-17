import Foundation

/// Joins a short gap between two committed segments so a command phrase split across an ordinary
/// mid-sentence commit boundary — "...fix the bug computer send" committed, then "the message..."
/// a moment later — is still found whole, rather than as two incomplete halves neither of which
/// is a configured phrase on its own.
public enum CommandObservationJoin {
    /// How many of the previous segment's own trailing words to carry forward as context — capped
    /// well above the longest phrase's own word count, since only that many could ever complete a
    /// split match.
    public static let maxTrailingWords = 6

    /// Below this gap, in seconds, two consecutive committed segments are treated as one
    /// continuous utterance for command matching — long enough to bridge an ordinary commit
    /// boundary mid-sentence, short enough that a genuine silence (the far more common shape of a
    /// deliberate pause before a command) is never joined into one.
    public static let maxGapSeconds: TimeInterval = 2

    /// Whether `previousSegmentEnd` and `currentSegmentStart` (both take-offset samples) are close
    /// enough to join.
    public static func shouldJoin(previousSegmentEnd: Int, currentSegmentStart: Int, sampleRate: Double) -> Bool {
        currentSegmentStart - previousSegmentEnd < Int(sampleRate * maxGapSeconds)
    }

    /// The observation `CommandDetector` matches against: `previousWords`' own trailing run (if
    /// any — empty when nothing should be joined, per `shouldJoin`) prepended to the current
    /// segment's own text, real word timing carried through unbroken across the join whenever the
    /// current segment's own timing is usable. A phrase entirely inside the prepended words was
    /// already found (or correctly rejected) while that earlier segment was itself processed, so
    /// this never double-fires one — the position gate alone rules it out: reaching the front of
    /// the join, not the end of the combined text, no longer satisfies it.
    public static func joinedObservation(
        previousWords: [Word], currentText: String, currentWordTimes: [SampleRange]?, currentAtOffset: Int
    ) -> CommandObservation {
        let trailing = Array(previousWords.suffix(maxTrailingWords))
        guard !trailing.isEmpty else {
            return CommandObservation(
                text: currentText, isFinal: true, wordTimes: currentWordTimes, atOffset: currentAtOffset)
        }
        let text = (trailing.map(\.text) + [currentText]).joined(separator: " ")
        let wordTimes = currentWordTimes.map { trailing.map(\.range) + $0 }
        return CommandObservation(text: text, isFinal: true, wordTimes: wordTimes, atOffset: currentAtOffset)
    }
}
