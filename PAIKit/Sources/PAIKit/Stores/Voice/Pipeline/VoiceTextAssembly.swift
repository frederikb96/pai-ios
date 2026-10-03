import Foundation

/// Turns a ledger into the one string a draft or message actually shows — the single place this
/// arithmetic lives, so a live take streaming into its draft and a recovered take healing later
/// both read the identical rule instead of two copies that can silently disagree.
public enum VoiceTextAssembly {
    /// The take's text: its live transcription, any batch-recovered segments and an inline `…`
    /// marker at every stretch the ledger's own `gaps` still lists as open, each placed by the
    /// take sample it ends at and joined by a space.
    ///
    /// Segments with empty text are skipped — the live path records delivery as one textless
    /// acknowledged range, and its words live in `liveText` instead.
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
        var parts: [(endSample: Int, text: String)] = []
        for live in ledger.liveText ?? [] where !live.text.isEmpty {
            parts.append((live.endSample, live.text))
        }
        for segment in ledger.segments where !segment.text.isEmpty {
            parts.append((segment.range.upperBound, segment.text))
        }
        for gap in ledger.gaps {
            parts.append((gap.range.upperBound, "…"))
        }
        return parts.sorted { $0.endSample < $1.endSample }.map(\.text).joined(separator: " ")
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
