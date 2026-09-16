import Foundation

/// Turns a call-mode take's ledger into the text a "send" should send, and says whether that text
/// is even ready to send yet. Reads only the shared `TranscriptLedger` value — never the pipeline
/// session that produces it — so this is provable against a hand-built ledger without any of the
/// pipeline's own machinery existing yet.
///
/// Every function below takes `[SampleRange]` rather than one range: a "stop" no longer sends,
/// only returns to wake mode with the turn's text held — so a turn can span several start/stop
/// cycles by the time "send" is finally heard, each contributing its own `collecting` range with
/// a stretch of wake-mode silence between them that must not be assembled into the message.
public enum CallMessageAssembler {

    /// Every range is ready to send when nothing in `ledger.gaps` overlaps any of them — the same
    /// "no gap, no send" rule `TranscriptLedger.delivered` is built on, applied to one turn's
    /// ranges rather than the whole take.
    public static func isCovered(_ ranges: [SampleRange], in ledger: TranscriptLedger) -> Bool {
        !ledger.gaps.contains { gap in ranges.contains { $0.overlaps(gap.range) } }
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
}
