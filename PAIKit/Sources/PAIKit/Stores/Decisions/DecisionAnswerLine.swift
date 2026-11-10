import Foundation

/// A picked answer as a line of the owner's own message. The server marks a decision answered
/// when a sent message carries a line of its own opening with `D<n> (<title>):` (the title
/// without its trailing periods) and takes the rest as the answer, so this form is a contract
/// with the backend and with the web client, which writes the same line.
public enum DecisionAnswerLine {
    public static func line(for decision: Decision, answer: String) -> String {
        "D\(decision.number) (\(titleWithoutTrailingPeriods(decision.title))): \(oneLine(answer))"
    }

    /// `draft` followed by `lines`, one per line, after whatever the draft already holds; the
    /// draft's trailing whitespace gives way to the single line break.
    public static func appending(_ lines: [String], toDraft draft: String) -> String {
        let joined = lines.joined(separator: "\n")
        let kept = draft.trimmingCharacters(in: trailingWhitespace)
        return kept.isEmpty ? joined : "\(kept)\n\(joined)"
    }

    private static let trailingWhitespace = CharacterSet.whitespacesAndNewlines

    private static func titleWithoutTrailingPeriods(_ title: String) -> String {
        var trimmed = Substring(title)
        while trimmed.last == "." { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// Every line break, with the whitespace around it, becomes one space: an answer that kept
    /// its breaks would end the line the server reads it from.
    private static func oneLine(_ answer: String) -> String {
        let collapsed = answer.replacingOccurrences(
            of: #"\s*\n\s*"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
