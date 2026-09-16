import Foundation

/// Turns the ledger's open gaps into batch-endpoint requests, and nothing else — no network, no
/// audio, so the coalescing, splitting and margin arithmetic is exhaustively testable without a
/// stub `URLProtocol`. `BatchBackfiller` is what actually executes a `Request`.
public enum BackfillPlanner {
    /// One second of audio margin added on both sides of a request — a word cut at the exact
    /// boundary is whole on at least one side of the seam `SeamMerge` then resolves.
    public static let marginSeconds = 1
    /// A single batch request never asks for more than this much audio — a five-minute cap so a
    /// failed upload loses little rather than the whole outage's worth of work.
    public static let maxRequestDurationSeconds = 300
    /// How many failed attempts on a *stable* link a gap tolerates before it is demoted rather
    /// than retried forever — a genuinely undecodable stretch stops costing a request every time
    /// the link comes back.
    public static let maxAttemptsBeforeDemotion = 3

    /// One coalesced stretch of audio worth asking the batch endpoint to transcribe.
    public struct Request: Sendable, Equatable {
        /// The gap's own range — what a produced `.batch` `Segment` should ultimately cover once
        /// `SeamMerge` trims away the margin.
        public let range: SampleRange
        /// What is actually sent for transcription — `range` expanded by the margin on both
        /// sides, clamped to what has actually been captured.
        public let audioRange: SampleRange
        /// The persisted gaps this request will resolve, for attempt-count bookkeeping once it
        /// succeeds or fails.
        public let gapRanges: [SampleRange]

        public init(range: SampleRange, audioRange: SampleRange, gapRanges: [SampleRange]) {
            self.range = range
            self.audioRange = audioRange
            self.gapRanges = gapRanges
        }
    }

    /// Which requests are ready to go out right now. Nothing at all unless the link is `.stable`
    /// — spending a request on a connection about to drop again wastes the one thing this design
    /// treats as free (the audio never goes anywhere) on the one thing it does not (a request that
    /// will likely fail mid-upload).
    public static func plan(gaps: [Gap], sampleRate: Int, capturedUpTo: Int, health: HealthState) -> [Request] {
        guard health == .stable else { return [] }
        let eligible = gaps.filter { !$0.demoted }.sorted { $0.range.lowerBound < $1.range.lowerBound }
        guard !eligible.isEmpty else { return [] }

        let marginSamples = marginSeconds * sampleRate
        let maxSamples = maxRequestDurationSeconds * sampleRate

        var requests: [Request] = []
        var run: [Gap] = []
        func flush() {
            guard !run.isEmpty else { return }
            requests.append(contentsOf: split(run, maxSamples: maxSamples, marginSamples: marginSamples, capturedUpTo: capturedUpTo))
            run = []
        }
        for gap in eligible {
            if let last = run.last, gap.range.lowerBound > last.range.upperBound {
                flush()
            }
            run.append(gap)
        }
        flush()
        return requests
    }

    /// Splits one coalesced run of adjacent/overlapping gaps into requests no longer than the
    /// duration cap, each carrying its own audio margin.
    private static func split(_ run: [Gap], maxSamples: Int, marginSamples: Int, capturedUpTo: Int) -> [Request] {
        let lower = run.map(\.range.lowerBound).min() ?? 0
        let upper = run.map(\.range.upperBound).max() ?? 0
        var requests: [Request] = []
        var start = lower
        while start < upper {
            let end = min(start + maxSamples, upper)
            let range = start..<end
            let audioLower = max(0, range.lowerBound - marginSamples)
            let audioUpper = min(capturedUpTo, range.upperBound + marginSamples)
            let coveredGaps = run.filter { $0.range.overlaps(range) }.map(\.range)
            requests.append(Request(range: range, audioRange: audioLower..<audioUpper, gapRanges: coveredGaps))
            start = end
        }
        return requests
    }

    /// Applies a failed attempt to one gap — incrementing its count and demoting it once the
    /// stable-link attempt budget is spent. A new stable episode resets nothing: the count belongs
    /// to the gap, not to the episode that failed it.
    public static func recordFailure(_ gap: Gap, error: String) -> Gap {
        let attempts = gap.attempts + 1
        return Gap(range: gap.range, attempts: attempts, lastError: error, demoted: attempts >= maxAttemptsBeforeDemotion)
    }
}
