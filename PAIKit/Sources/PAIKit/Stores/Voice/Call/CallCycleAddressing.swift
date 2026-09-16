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

    /// Every range in `ranges`, shifted by the same `base` — what a cycle's own
    /// `VoiceRecordingSession.acknowledgedRanges` is handed through wholesale, the acknowledged
    /// counterpart to `shift(_:by:)` for `[Segment]` below.
    public static func shift(_ ranges: [SampleRange], by base: Int) -> [SampleRange] {
        ranges.map { shift($0, by: base) }
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

    /// Translates the offline command engine's own `atOffset` — addressed from call entry in the
    /// wake-word listener's own coordinates, which advance through the wake-mode gaps *between*
    /// cycles that a cycle's own audio never sees — into the call ledger's addressing. Both
    /// counters advance by the same sample count on every chunk of audio captured while a cycle is
    /// open, so `atOffset - wakeOffsetAtCycleStart` is exactly how far into the cycle the
    /// detector's own window ended, the same quantity the cycle's own sample count tracks; adding
    /// `callTakeCollectedSamples` (the ledger position the cycle itself started from) lands it in
    /// the ledger's own addressing.
    ///
    /// This is what a spoken "stop"/"send" should be stamped with instead of the cycle's end —
    /// the end includes the offline detector's own latency and the wait for the final commit,
    /// during which more audio keeps being fed into the cycle, so stamping there put the command
    /// seconds beyond where `CommandWindowStripper`'s window could ever reach it.
    public static func translateWakeWordOffset(
        _ atOffset: Int, wakeOffsetAtCycleStart: Int, callTakeCollectedSamples: Int
    ) -> Int {
        callTakeCollectedSamples + (atOffset - wakeOffsetAtCycleStart)
    }
}
