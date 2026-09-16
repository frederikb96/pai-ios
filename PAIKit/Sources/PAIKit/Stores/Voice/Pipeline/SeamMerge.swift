import Foundation

/// Reconciles a set of segments whose ranges may overlap — deliberately, from a batch backfill
/// request's audio margin, or by accident, from two backfills racing on the same stretch — into
/// the ordered, non-duplicated set a ledger's assembled text is actually built from.
///
/// Never mutates `TranscriptLedger.segments` itself: a caller runs this over the current segment
/// list whenever it needs final text (after a new segment lands), the same way `coveredUpTo` is
/// derived rather than stored.
public enum SeamMerge {
    /// Which source wins when the same stretch is claimed twice — the batch model saw the widest
    /// context and is the better transcription, live-burst replays already-heard audio through a
    /// fresh socket, a first-pass live commit is the earliest and least corrected.
    static func precedence(_ source: Segment.Source) -> Int {
        switch source {
        case .live: return 0
        case .recovery: return 0
        case .liveBurst: return 1
        case .batch: return 2
        }
    }

    /// The longest run of trailing/leading words this heuristic will ever trim — past this, two
    /// segments repeating the same words for that long is more likely genuine repeated speech
    /// than a seam, so trimming further risks losing real words instead of a duplicate.
    static let maxFallbackOverlapWords = 8

    /// Produces the final segment list: every word placed in exactly one segment, ordered by
    /// where it sits in the take.
    public static func merge(_ segments: [Segment]) -> [Segment] {
        guard segments.count > 1 else { return segments }
        let ordered = segments.sorted { $0.range.lowerBound < $1.range.lowerBound }

        let wordTrimmed = trimByWordOwnership(ordered)
        let seamTrimmed = trimTextOverlapFallback(wordTrimmed.sorted { $0.range.lowerBound < $1.range.lowerBound })
        return seamTrimmed.filter { !$0.text.isEmpty }
    }

    /// For every segment carrying word timestamps: first drops any of its own words whose
    /// midpoint falls outside its own declared range — a batch segment's audio request reaches a
    /// margin beyond the gap it was asked to fill, and a word the model returns from that margin
    /// belongs to whatever segment already covers it, not to this one, however good the
    /// transcription. Only once that self-trim has narrowed a segment to what it actually owns
    /// does the cross-segment check apply: a word a higher-precedence segment's (now-narrowed)
    /// range also claims is dropped from this one. Two segments of *equal* precedence — two batch
    /// passes over a gap that grew between plan and apply, say — are resolved the same way: the
    /// one later in `ordered` (a stable sort, so the more recently added of an identical range)
    /// wins the word, so a genuine race between two backfill passes over the same stretch
    /// collapses to one copy rather than surviving as a duplicate neither pass's precedence alone
    /// would have dropped. A segment left with no surviving words is dropped entirely rather than
    /// kept as an empty husk.
    private static func trimByWordOwnership(_ ordered: [Segment]) -> [Segment] {
        let selfTrimmed = ordered.map { segment -> Segment in
            guard let words = segment.words else { return segment }
            let owned = words.filter { word in
                let midpoint = (word.range.lowerBound + word.range.upperBound) / 2
                return segment.range.contains(midpoint)
            }
            guard owned.count != words.count else { return segment }
            return Segment(range: segment.range, text: segment.text, words: owned, source: segment.source)
        }

        var result: [Segment] = []
        for (index, segment) in selfTrimmed.enumerated() {
            guard let words = segment.words else {
                result.append(segment)
                continue
            }
            let ownPrecedence = precedence(segment.source)
            let survivors = words.filter { word in
                let midpoint = (word.range.lowerBound + word.range.upperBound) / 2
                return !selfTrimmed.enumerated().contains { other in
                    guard other.offset != index, other.element.range.contains(midpoint) else { return false }
                    let otherPrecedence = precedence(other.element.source)
                    return otherPrecedence != ownPrecedence
                        ? otherPrecedence > ownPrecedence
                        : other.offset > index
                }
            }
            guard !survivors.isEmpty else { continue }
            let range = survivors.first!.range.lowerBound..<survivors.last!.range.upperBound
            result.append(
                Segment(
                    range: range, text: survivors.map(\.text).joined(separator: " "), words: survivors,
                    source: segment.source)
            )
        }
        return result
    }

    /// The fallback for whichever neighbouring pair still overlaps after word-level trimming —
    /// reached only when at least one side of the pair has no word timestamps to place words by,
    /// e.g. a plain `committed_transcript` the server ever sends with timestamps otherwise
    /// enabled. Trims the longest run that is both a suffix of the earlier segment's text and a
    /// prefix of the later one's, capped at `maxFallbackOverlapWords`, from the lower-precedence
    /// side.
    private static func trimTextOverlapFallback(_ ordered: [Segment]) -> [Segment] {
        var result: [Segment] = []
        for segment in ordered {
            guard let last = result.last, last.range.upperBound > segment.range.lowerBound else {
                result.append(segment)
                continue
            }
            guard last.words == nil || segment.words == nil else {
                // Both carry word timestamps — word-level trimming already resolved this pair;
                // a residual range overlap with no word overlap is the deliberate audio margin.
                result.append(segment)
                continue
            }
            let (trimmedLast, trimmedNext) = trimCommonBoundary(previous: last, next: segment)
            result[result.count - 1] = trimmedLast
            result.append(trimmedNext)
        }
        return result
    }

    private static func trimCommonBoundary(previous: Segment, next: Segment) -> (Segment, Segment) {
        let previousWords = previous.text.split(separator: " ").map(String.init)
        let nextWords = next.text.split(separator: " ").map(String.init)
        let upperBound = min(maxFallbackOverlapWords, previousWords.count, nextWords.count)
        guard upperBound > 0 else { return (previous, next) }

        var overlap = 0
        for candidate in stride(from: upperBound, through: 1, by: -1) {
            let suffix = previousWords.suffix(candidate).map { $0.lowercased() }
            let prefix = nextWords.prefix(candidate).map { $0.lowercased() }
            if suffix == prefix {
                overlap = candidate
                break
            }
        }
        guard overlap > 0 else { return (previous, next) }

        if precedence(next.source) >= precedence(previous.source) {
            let kept = previousWords.dropLast(overlap)
            let trimmed = Segment(
                range: previous.range, text: kept.joined(separator: " "), words: nil, source: previous.source)
            return (trimmed, next)
        } else {
            let kept = nextWords.dropFirst(overlap)
            let trimmed = Segment(range: next.range, text: kept.joined(separator: " "), words: nil, source: next.source)
            return (previous, trimmed)
        }
    }
}
