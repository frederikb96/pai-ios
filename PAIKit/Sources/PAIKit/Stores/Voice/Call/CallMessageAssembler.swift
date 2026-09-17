import Foundation

/// Turns a call-mode take's ledger into the text a "send" should send, and says whether that text
/// is even ready to send yet. Reads only the shared `TranscriptLedger` value — never the pipeline
/// session that produces it — so this is provable against a hand-built ledger without any of the
/// pipeline's own machinery existing yet.
///
/// Every function below takes `[SampleRange]` rather than one range: "stop" only returns to wake
/// mode with the turn's text held, never sending it — so a turn can span several start/stop
/// cycles by the time "send" is finally heard, each contributing its own `collecting` range with
/// a stretch of wake-mode silence between them that must not be assembled into the message.
public enum CallMessageAssembler {

    /// Every range is ready to send when no retryable gap in `ledger.gaps` overlaps any of them — the same
    /// "no gap, no send" rule `TranscriptLedger.delivered` is built on, applied to one turn's
    /// ranges rather than the whole take. A demoted gap is never retried, so waiting on it would
    /// hold the turn forever.
    public static func isCovered(_ ranges: [SampleRange], in ledger: TranscriptLedger) -> Bool {
        !ledger.gaps.contains { gap in !gap.demoted && ranges.contains { $0.overlaps(gap.range) } }
    }

    /// Joins every committed segment whose range falls inside any of `ranges`, in offset order,
    /// with a space — the same rule the architecture gives the ledger's own full-take text
    /// rebuild, applied here to one turn's ranges. A segment outside every range (an earlier
    /// wake-mode stretch, say) is excluded even if it happens to overlap the take otherwise.
    public static func assembledText(for ranges: [SampleRange], in ledger: TranscriptLedger) -> String {
        ledger.segments
            .filter { segment in ranges.contains { $0.overlaps(segment.range) } }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The same assembly as above, with every word `commands` recognized cut out of the segments
    /// that carry word timing (`CommandWindowStripper`). Without this, "send" itself — heard from
    /// `.collecting`, where it doubles as stop-and-send — lands as the tail end of the very
    /// message it triggered sending: Freddy's own "computer send the message" spoken into the
    /// message he meant to close. A segment with no `words` (a batch backfill result older than
    /// word-level timing, say) passes through unstripped rather than being dropped outright — an
    /// occasional stray command word left in is a far smaller cost than losing genuinely dictated
    /// text.
    public static func assembledText(
        for ranges: [SampleRange], in ledger: TranscriptLedger, strippingCommands commands: [CommandEvent],
        phraseSet: CommandPhraseSet = .defaults
    ) -> String {
        guard !commands.isEmpty else { return assembledText(for: ranges, in: ledger) }
        return assembledText(
            of: ledger.segments.filter { segment in ranges.contains { $0.overlaps(segment.range) } },
            sampleRate: ledger.sampleRate, strippingCommands: commands, phraseSet: phraseSet)
    }

    /// The same stripping over segments that are not in a ledger yet — an open cycle's own socket
    /// segments, already shifted into the call's addressing.
    public static func assembledText(
        of segments: [Segment], sampleRate: Int, strippingCommands commands: [CommandEvent],
        phraseSet: CommandPhraseSet = .defaults
    ) -> String {
        segments
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map { segment in
                guard !commands.isEmpty, let words = segment.words else { return segment.text }
                return CommandWindowStripper.strip(
                    words: words, commands: commands, phraseSet: phraseSet, sampleRate: Double(sampleRate))
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
