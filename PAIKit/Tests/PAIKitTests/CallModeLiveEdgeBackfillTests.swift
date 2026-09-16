import XCTest

@testable import PAIKit

/// Replays the exact write sequence call mode runs on a device — `CallModeController.persistCallLedger`
/// folding the call's ledger once a second, and `VoiceRecorderController.runBackfillLoop` planning
/// from whatever `gaps` the in-memory ledger holds and applying its outcome — using only the package
/// functions those two loops call. The batch model is simulated as a perfect transcriber of exactly
/// the audio it was handed, so any duplication below comes from the pipeline, not from the model.
///
/// The first two tests never pass `pendingLiveRange` to `folding` — that is deliberate: they
/// exercise the ledger and `SeamMerge` machinery on its own, without a live `VoiceRecordingSession`
/// in the loop, proving the defence-in-depth fixes (`applyingBackfill` narrowing a stale gap,
/// `SeamMerge` resolving two equal-precedence segments) hold even in a scenario where a healthy
/// connection's own tail is, for whatever reason, treated as a gap in the first place — and that
/// they are not, on their own, enough to stop every kind of duplication a slice boundary can
/// produce. The third test adds `pendingLiveRange`, proving the primary fix.
final class CallModeLiveEdgeBackfillTests: XCTestCase {
    private let rate = 16_000

    private struct Spoken { let text: String; let start: Double; let end: Double }

    private let script: [Spoken] = [
        Spoken(text: "testing", start: 0.00, end: 0.40),
        Spoken(text: "the", start: 0.45, end: 0.60),
        Spoken(text: "new", start: 0.65, end: 0.85),
        Spoken(text: "call", start: 0.90, end: 1.30),
        Spoken(text: "feature", start: 1.35, end: 1.90),
        Spoken(text: "I'm", start: 2.20, end: 2.40),
        Spoken(text: "started", start: 2.45, end: 2.90),
        Spoken(text: "the", start: 2.95, end: 3.10),
        Spoken(text: "app", start: 3.15, end: 3.60),
    ]

    private func samples(_ seconds: Double) -> Int { Int((seconds * Double(rate)).rounded()) }

    private func words(in audio: SampleRange) -> [Word] {
        script.compactMap { spoken in
            let range = samples(spoken.start)..<samples(spoken.end)
            let lower = max(range.lowerBound, audio.lowerBound)
            let upper = min(range.upperBound, audio.upperBound)
            guard lower < upper else { return nil }
            // A word cut by the end of the request's audio still comes back, timed to what was heard.
            return Word(range: lower..<upper, text: spoken.text)
        }
    }

    /// Mirrors `BatchBackfiller.run`'s own construction: words shifted to take offsets, the segment's
    /// range set to the un-margined `request.range`, source `.batch`.
    private func batchSegment(for request: BackfillPlanner.Request) -> Segment {
        let heard = words(in: request.audioRange)
        return Segment(
            range: request.range, text: heard.map(\.text).joined(separator: " "), words: heard, source: .batch)
    }

    private func liveCommit(through seconds: Double) -> Segment {
        let heard = words(in: 0..<samples(seconds))
        return Segment(
            range: heard.first!.range.lowerBound..<heard.last!.range.upperBound,
            text: heard.map(\.text).joined(separator: " "), words: heard, source: .live)
    }

    private func fold(
        _ ledger: TranscriptLedger, capturedUpTo seconds: Double, live: [Segment] = [], acknowledged: [SampleRange] = []
    )
        -> TranscriptLedger
    {
        // One open cycle from zero, exactly as `persistCallLedger` registers it.
        ledger.folding(
            liveSegments: live, capturedUpTo: samples(seconds), newlyAcknowledged: acknowledged,
            collecting: [0..<Int.max])
    }

    /// The same fold, but with the primary fix in play: `pendingLiveRange` covers everything
    /// captured but not yet acknowledged, exactly what `VoiceRecordingSession.pendingLiveRange`
    /// reports while genuinely still `.recording` with nothing committed yet. Nothing in this
    /// scenario ever drops, so `acknowledged` stays empty until the final live commit — the whole
    /// stretch from zero to `seconds` is "pending", never a gap.
    private func foldStillRecording(_ ledger: TranscriptLedger, capturedUpTo seconds: Double) -> TranscriptLedger {
        ledger.folding(
            liveSegments: [], capturedUpTo: samples(seconds), newlyAcknowledged: [],
            collecting: [0..<Int.max], pendingLiveRange: 0..<samples(seconds))
    }

    private func applyOnePass(_ ledger: TranscriptLedger) -> TranscriptLedger {
        let requests = BackfillPlanner.plan(
            gaps: ledger.gaps, sampleRate: rate, capturedUpTo: ledger.capturedUpTo, health: .stable)
        return ledger.applyingBackfill(
            newSegments: requests.map(batchSegment(for:)), resolved: requests.flatMap(\.gapRanges), failed: [])
    }

    private var truth: String { script.map(\.text).joined(separator: " ") }

    private func emptyCallLedger() -> TranscriptLedger {
        TranscriptLedger(takeId: "call", mode: .call, sampleRate: rate, draftKey: "s", preText: "")
    }

    /// A backfill pass that takes longer than one ledger tick applies its result onto a ledger whose
    /// tail gap has already grown. `applyingBackfill` now narrows the grown gap to whatever sliver
    /// past the resolved stretch is still uncovered, so the loop's next pass (300ms later, before
    /// any fold re-derives it) re-requests only that sliver instead of re-transcribing words the
    /// first pass already covered — and if a second pass ever does claim the same words a first
    /// pass already owns, `SeamMerge`'s equal-precedence tie-break collapses them to one.
    func testABackfillPassSpanningALedgerTickTranscribesEveryWordExactlyOnce() {
        var ledger = fold(emptyCallLedger(), capturedUpTo: 1.0)
        let firstPass = BackfillPlanner.plan(
            gaps: ledger.gaps, sampleRate: rate, capturedUpTo: ledger.capturedUpTo, health: .stable)
        XCTAssertEqual(firstPass.map(\.range), [0..<samples(1.0)], "the live edge is a gap on a healthy socket")

        ledger = fold(ledger, capturedUpTo: 2.0)  // the next ledger tick lands while the request is in flight
        ledger = ledger.applyingBackfill(
            newSegments: firstPass.map(batchSegment(for:)), resolved: firstPass.flatMap(\.gapRanges), failed: [])
        ledger = applyOnePass(ledger)  // reads the (now correctly narrowed) stale gap
        ledger = fold(ledger, capturedUpTo: 3.0)

        let committed = liveCommit(through: 3.6)
        ledger = fold(ledger, capturedUpTo: 4.0, live: [committed], acknowledged: [0..<samples(4.0)])

        XCTAssertEqual(CallMessageAssembler.assembledText(for: [0..<samples(4.0)], in: ledger), truth)
    }

    /// No race at all: every pass applies before the next tick. Without the primary fix
    /// (`pendingLiveRange`, deliberately not passed here — see the type's own doc comment), a
    /// healthy socket's not-yet-committed audio is still batch-transcribed in one-second slices,
    /// and a word cut at a slice boundary comes back doubled: once from the slice that cut it,
    /// again whole from its neighbour. `SeamMerge`'s self-trim only discards a word whose
    /// *midpoint* falls outside its own segment's declared range, which a word cut close to its
    /// end does not. This is exactly why the primary fix has to be "never slice the live edge at
    /// all" rather than "clean up the slices afterwards" — see the companion test below.
    func testACleanUninterruptedUtteranceStillDuplicatesASlicedWordWithoutThePrimaryFix() {
        var ledger = emptyCallLedger()
        for second in [1.0, 2.0, 3.0] {
            ledger = fold(ledger, capturedUpTo: second)
            ledger = applyOnePass(ledger)
        }
        let committed = liveCommit(through: 3.6)
        ledger = fold(ledger, capturedUpTo: 4.0, live: [committed], acknowledged: [0..<samples(4.0)])

        XCTAssertEqual(
            CallMessageAssembler.assembledText(for: [0..<samples(4.0)], in: ledger),
            "testing the new call feature I'm started the the app",
            "documents the bug: 'the' (spoken 2.95s-3.10s) survives on both sides of the 3.0s slice boundary")
    }

    /// The same script, the same one-second ledger ticks, this time with `pendingLiveRange` fed
    /// every tick exactly as `VoiceRecordingSession.pendingLiveRange` would report it for a
    /// healthy, still-recording connection. No gap ever opens while recording, so `applyOnePass`
    /// has nothing to plan and the whole utterance reaches the message from the one live commit
    /// that actually heard all of it — no slicing, so nothing to duplicate.
    func testACleanUninterruptedUtteranceWithThePrimaryFixNeverSlicesTheLiveEdgeAtAll() {
        var ledger = emptyCallLedger()
        for second in [1.0, 2.0, 3.0] {
            ledger = foldStillRecording(ledger, capturedUpTo: second)
            XCTAssertTrue(ledger.gaps.isEmpty, "a healthy connection's own tail must never open a gap")
            ledger = applyOnePass(ledger)
        }
        let committed = liveCommit(through: 3.6)
        ledger = fold(ledger, capturedUpTo: 4.0, live: [committed], acknowledged: [0..<samples(4.0)])

        XCTAssertEqual(CallMessageAssembler.assembledText(for: [0..<samples(4.0)], in: ledger), truth)
    }
}
