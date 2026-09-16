import Foundation

/// Shifts a collecting cycle's own segments — addressed from zero, exactly as a microphone-mode
/// take's are — into the call-wide ledger's own running position.
///
/// A microphone-mode take never needs this: one continuous `VoiceRecordingSession` for the whole
/// take means its own addressing already *is* the ledger's addressing. Call mode's "wake mode ⇄
/// recording mode" model opens a fresh session per start/stop cycle instead, each starting back
/// at zero, so the one thing genuinely new here — everything else (gap derivation, seam merging,
/// backfill planning) is the exact same machinery a microphone-mode take already proves — is this
/// arithmetic: a cycle's own committed segments, shifted by however many samples the call ledger
/// has already collected across every earlier cycle, before they are merged in.
public enum CallCycleAddressing {
    public static func shift(_ range: SampleRange, by base: Int) -> SampleRange {
        (base + range.lowerBound)..<(base + range.upperBound)
    }

    public static func shift(_ word: Word, by base: Int) -> Word {
        Word(range: shift(word.range, by: base), text: word.text, logprob: word.logprob)
    }

    public static func shift(_ segment: Segment, by base: Int) -> Segment {
        Segment(
            range: shift(segment.range, by: base), text: segment.text,
            words: segment.words?.map { shift($0, by: base) }, source: segment.source)
    }

    /// Every segment in `segments`, shifted by the same `base` — the convenience a cycle's own
    /// `committedSegments` array is handed through wholesale.
    public static func shift(_ segments: [Segment], by base: Int) -> [Segment] {
        segments.map { shift($0, by: base) }
    }
}
