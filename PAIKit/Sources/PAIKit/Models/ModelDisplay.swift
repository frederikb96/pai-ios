import Foundation

/// Formats a raw Claude wire model id — what `Session.liveModel`/`SseStatusEvent.liveModel`
/// actually carries (e.g. `"claude-opus-4-8"`) — for display in the session header's model
/// badge.
///
/// Deliberately a SEPARATE vocabulary from `CreateSessionStore.modelDisplayLabels`: that table
/// maps the small `claude --model` LAUNCH alias set (`sonnet`/`opus`/`haiku`/`fable`) to a label,
/// and never sees a real wire id. Conflating the two would mean every current and future wire id
/// needs its own alias entry there, for a table that exists for an unrelated purpose.
public enum ModelDisplay {
    /// Short labels for the ids of the current models. Not
    /// exhaustive by design — `fallbackLabel` covers everything else — so a newly released model
    /// shows a readable, if slightly rougher, label rather than nothing at all.
    private static let knownLabels: [String: String] = [
        "claude-fable-5-1": "Fable 5.1",
        "claude-mythos-5-1": "Mythos 5.1",
        "claude-fable-5": "Fable 5",
        "claude-opus-5-5": "Opus 5.5",
        "claude-opus-5": "Opus 5",
        "claude-opus-4-8": "Opus 4.8",
        "claude-opus-4-7": "Opus 4.7",
        "claude-opus-4-6": "Opus 4.6",
        "claude-sonnet-5": "Sonnet 5",
        "claude-sonnet-4-6": "Sonnet 4.6",
        "claude-haiku-4-5": "Haiku 4.5",
    ]

    /// `nil` for a `nil` or empty wire id — the caller decides what to show before anything has
    /// been reported, which is a different question from "an id arrived that this table
    /// predates."
    public static func label(forWireId wireId: String?) -> String? {
        guard let wireId, !wireId.isEmpty else { return nil }
        return knownLabels[wireId] ?? fallbackLabel(for: wireId)
    }

    /// Strips the `claude-` prefix and title-cases what is left, rather than showing the raw
    /// hyphenated wire string or hiding an id this table has not caught up to yet.
    private static func fallbackLabel(for wireId: String) -> String {
        let trimmed = wireId.hasPrefix("claude-") ? String(wireId.dropFirst("claude-".count)) : wireId
        return
            trimmed
            .split(separator: "-")
            .map { segment in segment.first?.isNumber == true ? String(segment) : segment.capitalized }
            .joined(separator: " ")
    }
}
