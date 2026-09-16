import Foundation

/// Turns a ledger into the one string a draft or message actually shows — the single place this
/// arithmetic lives, so a live take streaming into its draft and a recovered take healing later
/// both read the identical rule instead of two copies that can silently disagree.
public enum VoiceTextAssembly {
    /// A ledger's segments in take order, joined by a space, with an inline `…` marker at any
    /// stretch the ledger's own `gaps` still lists as open.
    ///
    /// 🚨 Reads `ledger.segments` as already deduplicated — never re-runs `SeamMerge.merge` on
    /// them. Both places that ever produce a ledger's `segments` (`folding`, `applyingBackfill`)
    /// already ran that merge once; running it a *second* time here is not merely redundant, it
    /// can hide a real bug. `SeamMerge`'s cross-segment check compares a word against *other*
    /// segments' current `range`, and a segment's `range` is itself recomputed from whichever of
    /// its words survive — so a second pass sees ranges the first pass's own trimming already
    /// widened, and can silently remove a lower-precedence segment's word that a broken first
    /// pass wrongly left in place, making a genuine self-trim regression look clean here. Always
    /// merge exactly once, at the point a ledger's `segments` is produced, never at every point
    /// it is read.
    ///
    /// Also reads `ledger.gaps` directly, never `ledger.derivedGaps(capturedUpTo:)` — a batch
    /// backfill resolves a gap by adding a `Segment` for it, not by extending `acknowledged` (that
    /// field means "the live socket confirmed this", which a batch pass never does), so
    /// re-deriving here would resurrect every gap `applyingBackfill` already closed. `gaps` is the
    /// up-to-date, authoritative record; `derivedGaps` is only ever for detecting what is newly
    /// open, which is `folding`'s job, not this one's.
    public static func assembledText(from ledger: TranscriptLedger) -> String {
        let parts: [(offset: Int, text: String)] =
            ledger.segments.map { ($0.range.lowerBound, $0.text) } + ledger.gaps.map { ($0.range.lowerBound, "…") }
        return parts.sorted { $0.offset < $1.offset }.map(\.text).joined(separator: " ")
    }

    /// `assembledText`, prefixed with `stt-rec: ` the same way `VoiceRecordingResult.prefixedText`
    /// is — empty stays empty rather than becoming a bare prefix, for the same reason that type's
    /// own doc comment gives: a blank speech bubble with no indication anything went wrong.
    public static func assembledPrefixedText(from ledger: TranscriptLedger) -> String {
        let text = assembledText(from: ledger)
        guard !text.isEmpty else { return "" }
        return "\(VoiceRecordingResult.sttPrefix)\(text)"
    }
}
