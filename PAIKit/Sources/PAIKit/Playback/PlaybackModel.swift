import Foundation

/// The arithmetic of a reply made of segments, shared with the web player (`playbackModel.ts`).
public enum PlaybackModel {
    /// How far ahead of a segment's end the next one is fetched (and so synthesised).
    public static let prefetchAheadMs = 15_000
    /// The step of the skip buttons, the lock screen's and the headset's.
    public static let skipMs = 10_000
    public static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    /// Each segment's length: the measured one once it is known, else the server's estimate.
    public static func segmentDurationsMs(_ manifest: PlaybackManifest, measured: [Int: Int]) -> [Int] {
        manifest.segments.map { measured[$0.index] ?? $0.durationMs ?? $0.estMs }
    }

    /// Which segment a position inside the whole reply falls in, and how far into it.
    public static func locate(durationsMs: [Int], positionMs: Int) -> (index: Int, offsetMs: Int) {
        let last = durationsMs.count - 1
        var rest = max(positionMs, 0)
        for index in 0..<max(last, 0) {
            if rest < durationsMs[index] { return (index, rest) }
            rest -= durationsMs[index]
        }
        return (max(last, 0), min(rest, durationsMs.last ?? 0))
    }

    /// Where a time inside one segment sits in the whole reply.
    public static func positionOf(durationsMs: [Int], index: Int, offsetMs: Int) -> Int {
        durationsMs.prefix(index).reduce(0, +) + offsetMs
    }

    public static func formatClock(_ ms: Int) -> String {
        let total = max((Double(ms) / 1000).rounded(), 0)
        let seconds = Int(total)
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }

    /// What a reply says, minus the `pai-file:` lines that are attachments and the `{{D<n>}}`
    /// lines that are decision cards (``DecisionMarkers``), neither of them speech.
    public static func replyText(_ content: String?) -> String {
        guard let content else { return "" }
        let kept = content.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("pai-file:") }
            .joined(separator: "\n")
        var prose: [String] = []
        for segment in DecisionMarkers.split(kept) {
            if case .markdown(let text) = segment { prose.append(text) }
        }
        return prose.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether a reply's text has anything to read aloud; the server still answers 404 for one that is all code.
    public static func hasSpeech(_ content: String?) -> Bool {
        !replyText(content).isEmpty
    }

    /// A reply the Listen chip is drawn for.
    public static func isPlayable(_ message: Message) -> Bool {
        message.type == .assistant && hasSpeech(message.content)
    }

    /// The first words of a reply, plain, for the player to name what it is reading.
    public static func snippet(of message: Message, max: Int = 60) -> String {
        snippet(ofContent: message.content, max: max)
    }

    public static func snippet(ofContent content: String?, max: Int = 60) -> String {
        var plain = replyText(content)
        plain = plain.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        plain = plain.replacingOccurrences(of: "[`*_#>~|]", with: "", options: .regularExpression)
        plain = plain.replacingOccurrences(of: "\\[([^\\]]*)\\]\\([^)]*\\)", with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if plain.isEmpty { return "Reply" }
        guard plain.count > max else { return plain }
        return plain.prefix(max).trimmingCharacters(in: .whitespaces) + "…"
    }
}
