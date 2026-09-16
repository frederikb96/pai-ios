import Foundation

/// Turns a range of a call-mode take's ledger into the text a "stop" boundary should send, and
/// says whether that range is even ready to send yet. Reads only the shared `TranscriptLedger`
/// value — never the pipeline session that produces it — so this is provable against a
/// hand-built ledger without any of the pipeline's own machinery existing yet.
public enum CallMessageAssembler {

    /// `range` is ready to send when nothing in `ledger.gaps` overlaps it — the same "no gap, no
    /// send" rule `TranscriptLedger.delivered` is built on, applied to one boundary's stretch
    /// rather than the whole take.
    public static func isCovered(_ range: SampleRange, in ledger: TranscriptLedger) -> Bool {
        !ledger.gaps.contains { $0.range.overlaps(range) }
    }

    /// Joins every committed segment whose range falls inside `range`, in offset order, with a
    /// space — the same rule the architecture gives the ledger's own full-take text rebuild,
    /// applied here to one boundary's slice. Segments outside `range` (an earlier "collecting"
    /// stretch, say) are excluded even if they happen to overlap.
    public static func assembledText(for range: SampleRange, in ledger: TranscriptLedger) -> String {
        ledger.segments
            .filter { $0.range.overlaps(range) }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
