import XCTest

@testable import PAIKit

final class BackfillPlannerTests: XCTestCase {

    /// The gate every other behaviour sits behind: no requests at all unless the link is
    /// `.stable`, however many gaps are waiting.
    func testNoRequestsUnlessTheLinkIsStable() {
        let gaps = [Gap(range: 0..<16000)]
        XCTAssertTrue(BackfillPlanner.plan(gaps: gaps, sampleRate: 16000, capturedUpTo: 16000, health: .unstable).isEmpty)
        XCTAssertTrue(BackfillPlanner.plan(gaps: gaps, sampleRate: 16000, capturedUpTo: 16000, health: .offline).isEmpty)
        XCTAssertTrue(BackfillPlanner.plan(gaps: gaps, sampleRate: 16000, capturedUpTo: 16000, health: .connecting).isEmpty)
    }

    func testDemotedGapsAreNeverPlanned() {
        let gaps = [Gap(range: 0..<16000, attempts: 3, demoted: true)]
        XCTAssertTrue(BackfillPlanner.plan(gaps: gaps, sampleRate: 16000, capturedUpTo: 16000, health: .stable).isEmpty)
    }

    func testASingleGapBecomesOneRequestWithMarginOnBothSides() {
        let sampleRate = 16000
        let gaps = [Gap(range: 32000..<48000)]  // 2s..3s into the take
        let requests = BackfillPlanner.plan(gaps: gaps, sampleRate: sampleRate, capturedUpTo: 80000, health: .stable)
        XCTAssertEqual(requests.count, 1)
        let request = try! XCTUnwrap(requests.first)
        XCTAssertEqual(request.range, 32000..<48000)
        XCTAssertEqual(request.audioRange, 16000..<64000, "one second of margin on each side")
        XCTAssertEqual(request.gapRanges, [32000..<48000])
    }

    /// The margin must clamp rather than reach before the start of the take or past what has
    /// actually been captured.
    func testMarginClampsAtTheEdgesOfTheTake() {
        let sampleRate = 16000
        let gapNearStart = [Gap(range: 0..<8000)]
        let startRequest = try! XCTUnwrap(
            BackfillPlanner.plan(gaps: gapNearStart, sampleRate: sampleRate, capturedUpTo: 8000, health: .stable).first
        )
        XCTAssertEqual(startRequest.audioRange.lowerBound, 0)

        let gapNearEnd = [Gap(range: 72000..<80000)]
        let endRequest = try! XCTUnwrap(
            BackfillPlanner.plan(gaps: gapNearEnd, sampleRate: sampleRate, capturedUpTo: 80000, health: .stable).first
        )
        XCTAssertEqual(endRequest.audioRange.upperBound, 80000)
    }

    /// Adjacent (touching) gaps coalesce into a single request rather than two overlapping ones —
    /// the whole point of coalescing is one upload instead of two that would double-cover their
    /// shared margin.
    func testAdjacentGapsCoalesceIntoOneRequest() {
        let sampleRate = 16000
        let gaps = [Gap(range: 0..<16000), Gap(range: 16000..<32000)]
        let requests = BackfillPlanner.plan(gaps: gaps, sampleRate: sampleRate, capturedUpTo: 32000, health: .stable)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.range, 0..<32000)
        XCTAssertEqual(requests.first?.gapRanges, [0..<16000, 16000..<32000])
    }

    func testGapsWithARealGapBetweenThemStaySeparateRequests() {
        let sampleRate = 16000
        let gaps = [Gap(range: 0..<16000), Gap(range: 64000..<80000)]
        let requests = BackfillPlanner.plan(gaps: gaps, sampleRate: sampleRate, capturedUpTo: 80000, health: .stable)
        XCTAssertEqual(requests.count, 2)
    }

    /// A run longer than the five-minute cap must be split into consecutive chunks, each still
    /// bounded, so one failed upload never costs the whole outage's worth of work.
    func testARunLongerThanTheCapSplitsIntoConsecutiveChunks() {
        let sampleRate = 16000
        let elevenMinutes = 11 * 60 * sampleRate
        let gaps = [Gap(range: 0..<elevenMinutes)]
        let requests = BackfillPlanner.plan(gaps: gaps, sampleRate: sampleRate, capturedUpTo: elevenMinutes, health: .stable)
        XCTAssertEqual(requests.count, 3, "5 + 5 + 1 minutes")
        XCTAssertEqual(requests[0].range, 0..<(5 * 60 * sampleRate))
        XCTAssertEqual(requests[1].range, (5 * 60 * sampleRate)..<(10 * 60 * sampleRate))
        XCTAssertEqual(requests[2].range, (10 * 60 * sampleRate)..<elevenMinutes)
        // Consecutive: the request list forms one continuous cover of the whole run.
        for (a, b) in zip(requests, requests.dropFirst()) {
            XCTAssertEqual(a.range.upperBound, b.range.lowerBound)
        }
    }

    // MARK: - recordFailure / demotion

    /// The sharp case the block leader's report names by name: after two failed bursts on a
    /// stable link, the range is not retried a third time — it is exactly at the demotion budget
    /// (three attempts) that the flag flips.
    func testAGapIsDemotedOnceItsFailureCountReachesTheAttemptBudget() {
        var gap = Gap(range: 0..<16000)
        gap = BackfillPlanner.recordFailure(gap, error: "timeout")
        XCTAssertEqual(gap.attempts, 1)
        XCTAssertFalse(gap.demoted)
        gap = BackfillPlanner.recordFailure(gap, error: "timeout")
        XCTAssertEqual(gap.attempts, 2)
        XCTAssertFalse(gap.demoted)
        gap = BackfillPlanner.recordFailure(gap, error: "timeout")
        XCTAssertEqual(gap.attempts, 3)
        XCTAssertTrue(gap.demoted, "the third stable-link failure spends the attempt budget")
    }

    /// A fresh stable episode must not reset a gap's attempt count — the budget belongs to the
    /// gap, and a genuinely undecodable stretch must eventually stop being retried at all.
    func testRecordFailureNeverResetsTheCountItOnlyEverIncrementsIt() {
        var gap = Gap(range: 0..<16000, attempts: 2)
        gap = BackfillPlanner.recordFailure(gap, error: "still failing")
        XCTAssertEqual(gap.attempts, 3)
        XCTAssertTrue(gap.demoted)
    }
}
