import XCTest

@testable import PAIKit

final class SeamMergeTests: XCTestCase {

    func testNonOverlappingSegmentsPassThroughUnchanged() {
        let segments = [
            Segment(range: 0..<1000, text: "hello", source: .live),
            Segment(range: 1000..<2000, text: "world", source: .live),
        ]
        XCTAssertEqual(SeamMerge.merge(segments), segments)
    }

    /// The sharpest case the design calls out by name: a word whose midpoint sits inside two
    /// segments' ranges (the deliberate audio margin a batch backfill request carries around a
    /// gap) must be kept from the higher-precedence one and dropped from the other, not kept
    /// twice and not dropped from both.
    func testAWordOwnedByTwoSegmentsIsKeptOnlyFromTheHigherPrecedenceOne() {
        let live = Segment(
            range: 0..<48000, text: "hello there friend",
            words: [
                Word(range: 0..<16000, text: "hello"),
                Word(range: 16000..<32000, text: "there"),
                Word(range: 32000..<48000, text: "friend"),
            ], source: .live
        )
        // The batch backfill's audio margin overlapped the tail of the live segment — it also
        // transcribed "friend", plus new words past where the live segment's coverage ends.
        let batch = Segment(
            range: 32000..<80000, text: "friend how are you",
            words: [
                Word(range: 32000..<48000, text: "friend"),
                Word(range: 48000..<64000, text: "how"),
                Word(range: 64000..<72000, text: "are"),
                Word(range: 72000..<80000, text: "you"),
            ], source: .batch
        )

        let merged = SeamMerge.merge([live, batch])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "hello there")
        XCTAssertEqual(merged[1].text, "friend how are you")
        // The word appears exactly once across every surviving segment.
        let allWords = merged.flatMap { $0.words ?? [] }.map(\.text)
        XCTAssertEqual(allWords.filter { $0 == "friend" }.count, 1)
    }

    /// A live segment entirely swallowed by a later, wider batch segment (the live-burst tail
    /// demoted and then fully re-covered by the batch backfill) must disappear rather than leave
    /// an empty husk.
    func testASegmentWithEveryWordClaimedByAHigherPrecedenceOneIsDroppedEntirely() {
        let liveBurst = Segment(
            range: 10000..<20000, text: "partial",
            words: [Word(range: 10000..<20000, text: "partial")], source: .liveBurst
        )
        let batch = Segment(
            range: 0..<30000, text: "the whole phrase",
            words: [
                Word(range: 0..<10000, text: "the"),
                Word(range: 10000..<20000, text: "whole"),
                Word(range: 20000..<30000, text: "phrase"),
            ], source: .batch
        )
        let merged = SeamMerge.merge([liveBurst, batch])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.source, .batch)
    }

    /// The no-timestamp fallback: when at least one side of an overlapping pair carries no word
    /// timestamps, the longest common run at the seam is trimmed from the lower-precedence side.
    func testNoTimestampFallbackTrimsTheLongestCommonRunAtTheSeam() {
        let earlier = Segment(range: 0..<50000, text: "the quick brown fox jumps", words: nil, source: .live)
        let later = Segment(range: 40000..<90000, text: "fox jumps over the lazy dog", words: nil, source: .batch)

        let merged = SeamMerge.merge([earlier, later])

        XCTAssertEqual(merged.count, 2)
        // "fox jumps" is the longest common suffix/prefix; trimmed from `earlier` since `later`
        // (batch) outranks it.
        XCTAssertEqual(merged[0].text, "the quick brown")
        XCTAssertEqual(merged[1].text, "fox jumps over the lazy dog")
    }

    /// The fallback must never trim more than its cap, even when every word happens to repeat —
    /// past that length, repetition reads as genuine speech rather than a seam artifact.
    func testNoTimestampFallbackNeverTrimsMoreThanTheCap() {
        let repeated = Array(repeating: "la", count: 10).joined(separator: " ")
        let earlier = Segment(range: 0..<50000, text: repeated, words: nil, source: .live)
        let later = Segment(range: 40000..<90000, text: repeated, words: nil, source: .batch)

        let merged = SeamMerge.merge([earlier, later])

        let earlierWordCount = merged[0].text.split(separator: " ").count
        XCTAssertEqual(earlierWordCount, 2, "trimmed exactly the 8-word cap from the 10-word segment")
    }

    /// Two segments with a genuine gap between them (no overlap at all) must not be touched by
    /// the fallback — there is nothing to trim.
    func testNoTimestampFallbackLeavesNonOverlappingSegmentsAlone() {
        let earlier = Segment(range: 0..<10000, text: "hello", words: nil, source: .live)
        let later = Segment(range: 20000..<30000, text: "world", words: nil, source: .live)
        XCTAssertEqual(SeamMerge.merge([earlier, later]), [earlier, later])
    }

    func testASingleSegmentIsReturnedUnchanged() {
        let segment = Segment(range: 0..<1000, text: "solo", source: .live)
        XCTAssertEqual(SeamMerge.merge([segment]), [segment])
    }

    // MARK: - Two segments of equal precedence claiming the same words

    /// Two `.batch` passes over the same stretch — the shape a backfill race or a stale-gap
    /// replan produces — used to both keep every word, since the old cross-segment check only
    /// dropped a word claimed by a *strictly higher* precedence segment. The later one (a stable
    /// sort keeps the earlier-appended segment first for an identical range) must now win.
    func testTwoBatchSegmentsOverTheIdenticalRangeCollapseToOneRatherThanBothSurviving() {
        let first = Segment(
            range: 0..<32000, text: "testing the new call",
            words: [
                Word(range: 0..<8000, text: "testing"), Word(range: 8000..<16000, text: "the"),
                Word(range: 16000..<24000, text: "new"), Word(range: 24000..<32000, text: "call"),
            ], source: .batch)
        let second = Segment(
            range: 0..<32000, text: "testing the new call",
            words: [
                Word(range: 0..<8000, text: "testing"), Word(range: 8000..<16000, text: "the"),
                Word(range: 16000..<24000, text: "new"), Word(range: 24000..<32000, text: "call"),
            ], source: .batch)

        let merged = SeamMerge.merge([first, second])

        XCTAssertEqual(merged.count, 1, "an exact duplicate must collapse to a single segment")
        XCTAssertEqual(merged.first?.text, "testing the new call")
    }

    /// The same resolution for a *partial* overlap between two equal-precedence segments — only
    /// the contested words drop from the earlier one, its own words survive.
    func testTwoBatchSegmentsWithAPartialOverlapEachKeepOnlyTheirOwnWords() {
        let earlier = Segment(
            range: 0..<24000, text: "testing the new",
            words: [
                Word(range: 0..<8000, text: "testing"), Word(range: 8000..<16000, text: "the"),
                Word(range: 16000..<24000, text: "new"),
            ], source: .batch)
        let later = Segment(
            range: 16000..<32000, text: "new call",
            words: [Word(range: 16000..<24000, text: "new"), Word(range: 24000..<32000, text: "call")],
            source: .batch)

        let merged = SeamMerge.merge([earlier, later])

        XCTAssertEqual(merged.map(\.text), ["testing the", "new call"])
        let allWords = merged.flatMap { $0.words ?? [] }.map(\.text)
        XCTAssertEqual(allWords.filter { $0 == "new" }.count, 1, "the contested word survives on exactly one side")
    }
}
