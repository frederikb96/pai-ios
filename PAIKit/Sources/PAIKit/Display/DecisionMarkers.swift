import Foundation

/// A decision embedded in an assistant reply: a line that is exactly `{{D<n>}}` (up to three
/// spaces of indent, as markdown allows before a paragraph, and trailing spaces or tabs) stands
/// for the session's decision `n` and is drawn as its card. Inside a fenced code block it is code
/// and stays text, so a reply can show the marker itself. Swift port of the web's
/// `utils/decisionMarkers.ts`; the contract is pai-cloud's `docs/architecture/notifications.md` →
/// Decisions.
public enum DecisionMarkers {

    /// One piece of a reply cut at its markers.
    public enum Segment: Equatable, Sendable {
        case markdown(String)
        case decision(Int)
    }

    /// The reply cut at its decision markers: the markdown between them, and the numbers they
    /// name, in order. A chunk that is only whitespace is dropped; text without a marker is one
    /// segment.
    public static func split(_ text: String) -> [Segment] {
        guard text.contains("{{D") else { return [.markdown(text)] }
        var segments: [Segment] = []
        var chunk: [Substring] = []
        var fence: (character: Character, length: Int)?

        func flush() {
            let joined = chunk.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(joined))
            }
            chunk = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if closesFence(line, character: open.character, length: open.length) { fence = nil }
                chunk.append(line)
                continue
            }
            if let opened = fenceOpening(line) {
                fence = opened
                chunk.append(line)
                continue
            }
            if let number = markerNumber(line) {
                flush()
                segments.append(.decision(number))
                continue
            }
            chunk.append(line)
        }
        flush()
        return segments
    }

    /// The decision numbers `text` embeds, in order.
    public static func embeddedNumbers(in text: String) -> [Int] {
        guard text.contains("{{D") else { return [] }
        return split(text).compactMap { if case .decision(let number) = $0 { number } else { nil } }
    }

    /// The decision numbers one message embeds: only an assistant reply's own text can.
    public static func embeddedNumbers(of message: Message) -> [Int] {
        guard message.type == .assistant, let content = message.content else { return [] }
        return embeddedNumbers(in: content)
    }

    // MARK: - Placing the decisions no reply embeds

    /// Where the open decisions no loaded message embeds are drawn instead: under the last
    /// assistant message of the turn that created them, once that turn has ended, so a forgotten
    /// marker never leaves a question only in the pin. Keyed by message id, numbers ascending.
    ///
    /// A turn is the run of rows after a prompt; it has ended at its `duration` row (written once
    /// at the end of every main-agent turn) or at the next prompt. The turn creating a decision
    /// runs on from the last row timestamped at or before the decision's `createdAt`. Nothing is
    /// placed while that turn still runs, nor when the loaded window may not hold its start
    /// (`hasOlder` with no loaded row before the decision); an end beyond the loaded rows reads as
    /// a turn still running. A card appears once the rows that decide its place are there, rather
    /// than in a place it would later leave.
    ///
    /// `embedded` is what every loaded message embeds (``embeddedNumbers(of:)`` over the window),
    /// passed in so a caller can remember it per message instead of scanning every reply again.
    public static func placeUnembedded(
        messages: [Message], decisions: [Decision], embedded: Set<Int>, hasOlder: Bool
    ) -> [Int: [Int]] {
        var placed: [Int: [Int]] = [:]
        let waiting = decisions.filter { $0.state == .open && !embedded.contains($0.number) }
        guard !waiting.isEmpty, !messages.isEmpty else { return placed }
        let times = messages.map { $0.timestamp.flatMap(IsoTimestamp.date(from:)) }

        for decision in waiting {
            guard let created = IsoTimestamp.date(from: decision.createdAt) else { continue }
            var start = -1
            for index in messages.indices {
                if let time = times[index], time <= created { start = index }
            }
            if start == -1, hasOlder { continue }
            var last: Message?
            var ended = false
            for index in max(start, 0)..<messages.count {
                let message = messages[index]
                if endsTurn(message) || (index > start && startsTurn(message)) {
                    ended = true
                    break
                }
                if message.type == .assistant { last = message }
            }
            guard ended, let last else { continue }
            placed[last.id, default: []].append(decision.number)
        }
        return placed.mapValues { $0.sorted() }
    }

    /// The `user` subtypes that put something in front of the agent and so start a turn.
    private static let promptSubtypes: Set<String?> = [
        nil, "resent", "pai_message", "agent_message", "scheduled", "command", "interrupt",
    ]

    private static func startsTurn(_ message: Message) -> Bool {
        message.type == .user && promptSubtypes.contains(message.subtype)
    }

    private static func endsTurn(_ message: Message) -> Bool {
        message.type == .system && message.subtype == "duration"
    }

    // MARK: - Line grammar

    /// Up to three leading spaces, as markdown allows before a block.
    private static func dropIndent(_ line: Substring) -> Substring? {
        let spaces = line.prefix { $0 == " " }.count
        return spaces <= 3 ? line.dropFirst(spaces) : nil
    }

    /// The number of a line that is exactly `{{D<n>}}`, trailing spaces or tabs allowed.
    private static func markerNumber(_ line: Substring) -> Int? {
        guard var rest = dropIndent(line), rest.hasPrefix("{{D") else { return nil }
        rest = rest.dropFirst(3)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.hasPrefix("}}") else { return nil }
        rest = rest.dropFirst(2)
        return rest.allSatisfy { $0 == " " || $0 == "\t" } ? number : nil
    }

    /// A fence opening: three or more backticks or tildes, anything after.
    private static func fenceOpening(_ line: Substring) -> (character: Character, length: Int)? {
        guard let rest = dropIndent(line), let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    /// A closing fence: the opening one's character, at least as many, nothing after.
    private static func closesFence(_ line: Substring, character: Character, length: Int) -> Bool {
        guard let rest = dropIndent(line), rest.first == character else { return false }
        let run = rest.prefix { $0 == character }.count
        guard run >= length else { return false }
        return rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
