import Foundation
import XCTest

@testable import PAIKit

/// Every method is `async` even where nothing inside it awaits anything — see
/// `TranscriptStoreTests`'s doc comment for why a `@MainActor` `XCTestCase` needs that on Linux.
@MainActor
final class SearchStateTests: XCTestCase {

    func testOpenActivatesSearch() async {
        let state = TranscriptSearchState()
        state.open()
        XCTAssertTrue(state.isActive)
    }

    func testCloseResetsEverythingIncludingTheQuery() async {
        let state = TranscriptSearchState()
        state.open()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [1])
        state.applyFindResult(total: 3, capped: true, serverMatchedIds: [1])
        state.commitLanding(outerIndex: 0, messageId: 1, inner: (0, 1))
        state.requestNext()

        state.close()

        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.query, "")
        XCTAssertNil(state.kind)
        XCTAssertFalse(state.loading)
        XCTAssertNil(state.error)
        XCTAssertEqual(state.total, 0)
        XCTAssertFalse(state.capped)
        XCTAssertNil(state.outerIndex)
        XCTAssertNil(state.currentMessageId)
        XCTAssertNil(state.inner)
        XCTAssertTrue(state.matchedIds.isEmpty)
        XCTAssertNil(state.consumePendingStep())
    }

    // MARK: - Stepping requests

    func testRequestNextIsConsumedOnceAndThenGone() async {
        let state = TranscriptSearchState()
        state.requestNext()

        XCTAssertEqual(state.consumePendingStep(), .next)
        XCTAssertNil(state.consumePendingStep())
    }

    func testRequestPreviousOverridesAPreviouslyPendingNext() async {
        let state = TranscriptSearchState()
        state.requestNext()
        state.requestPrevious()

        XCTAssertEqual(state.consumePendingStep(), .previous)
    }

    // MARK: - beginFind / applyFindResult

    /// The instant client-side set `beginFind` painted is only a preview of what was loaded when
    /// the request was SENT — once the server answers, its list must win outright, even in text
    /// mode, or a `locate` that jumps to a message the preview never saw (unloaded at request
    /// time) leaves that message permanently unmatched with no way back in. Leaving the preview in
    /// place here was the actual bug, proved live on the web this ported from.
    func testApplyFindResultReplacesMatchedIdsInTextModeToo() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [7])

        state.applyFindResult(total: 5, capped: false, serverMatchedIds: [2, 9])

        XCTAssertEqual(state.matchedIds, [2, 9], "the server's list must win outright, not the pre-fetch preview")
        XCTAssertEqual(state.total, 5)
        XCTAssertFalse(state.loading)
    }

    func testApplyFindResultReplacesMatchedIdsInKindMode() async {
        let state = TranscriptSearchState()
        state.kind = .boundary
        state.beginFind(instantMatchedIds: [])

        state.applyFindResult(total: 2, capped: false, serverMatchedIds: [3, 9])

        XCTAssertEqual(state.matchedIds, [3, 9])
    }

    func testClearResultsLeavesQueryAndKindAloneButResetsEverythingElse() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [1])
        state.applyFindResult(total: 3, capped: true, serverMatchedIds: [1])
        state.commitLanding(outerIndex: 0, messageId: 1, inner: (0, 1))

        state.clearResults()

        XCTAssertEqual(state.query, "needle", "clearResults is not close() — an emptied query calls this on its own")
        XCTAssertEqual(state.total, 0)
        XCTAssertNil(state.outerIndex)
        XCTAssertNil(state.currentMessageId)
        XCTAssertTrue(state.matchedIds.isEmpty)
    }

    // MARK: - commitLanding / currentHit

    func testCommitLandingSetsCurrentHit() async {
        let state = TranscriptSearchState()
        state.commitLanding(outerIndex: 2, messageId: 42, inner: (1, 3))

        XCTAssertEqual(state.outerIndex, 2)
        XCTAssertEqual(state.currentHit?.messageId, 42)
        XCTAssertEqual(state.currentHit?.inner?.ordinal, 1)
        XCTAssertEqual(state.currentHit?.inner?.count, 3)
    }

    /// A kind hit, or a text hit that resolved to zero occurrences in the loaded rendered text —
    /// still a row-level landing, no inner counter.
    func testCommitLandingWithNoInnerLeavesTheRowLevelLandingOnly() async {
        let state = TranscriptSearchState()
        state.commitLanding(outerIndex: 0, messageId: 42, inner: nil)

        XCTAssertEqual(state.currentHit?.messageId, 42)
        XCTAssertNil(state.currentHit?.inner)
    }

    func testStepInnerMovesTheOrdinalWithoutTouchingTheOuterPosition() async {
        let state = TranscriptSearchState()
        state.commitLanding(outerIndex: 0, messageId: 42, inner: (0, 3))

        state.stepInner(to: 1)

        XCTAssertEqual(state.outerIndex, 0)
        XCTAssertEqual(state.currentMessageId, 42)
        XCTAssertEqual(state.inner?.ordinal, 1)
        XCTAssertEqual(state.inner?.count, 3)
    }

    // MARK: - Stepping decisions

    func testNextStepsTheInnerOrdinalBeforeMovingTheOuterIndex() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.commitLanding(outerIndex: 0, messageId: 1, inner: (0, 2))

        XCTAssertEqual(state.next(hitCount: 3), .innerOnly(ordinal: 1))
    }

    func testNextMovesTheOuterIndexOnceTheInnerOrdinalIsExhausted() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.commitLanding(outerIndex: 0, messageId: 1, inner: (1, 2))

        XCTAssertEqual(state.next(hitCount: 3), .outerIndex(1))
    }

    /// A kind hit has no inner ordinal at all — every `next()` moves the outer index directly.
    func testNextOnAKindHitAlwaysMovesTheOuterIndex() async {
        let state = TranscriptSearchState()
        state.kind = .boundary
        state.commitLanding(outerIndex: 0, messageId: 1, inner: nil)

        XCTAssertEqual(state.next(hitCount: 3), .outerIndex(1))
    }

    func testNextWrapsFromTheLastHitBackToTheFirst() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.commitLanding(outerIndex: 1, messageId: 2, inner: nil)

        XCTAssertEqual(state.next(hitCount: 2), .outerIndex(0))
    }

    func testPreviousStepsTheInnerOrdinalBeforeMovingTheOuterIndex() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.commitLanding(outerIndex: 0, messageId: 1, inner: (1, 2))

        XCTAssertEqual(state.previous(hitCount: 3), .innerOnly(ordinal: 0))
    }

    func testPreviousWrapsFromTheFirstHitBackToTheLast() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.commitLanding(outerIndex: 0, messageId: 1, inner: nil)

        XCTAssertEqual(state.previous(hitCount: 2), .outerIndex(1))
    }

    func testSteppingWithNoHitsDoesNothing() async {
        let state = TranscriptSearchState()
        XCTAssertEqual(state.next(hitCount: 0), .none)
        XCTAssertEqual(state.previous(hitCount: 0), .none)
    }

    // MARK: - Summary text

    func testResultsSummaryReportsPositionAndTotal() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [])
        state.applyFindResult(total: 2, capped: false, serverMatchedIds: [])
        state.commitLanding(outerIndex: 0, messageId: 1, inner: nil)

        XCTAssertEqual(state.resultsSummary, "1/2")
    }

    func testResultsSummaryMarksACappedCountWithAPlus() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [])
        state.applyFindResult(total: 5000, capped: true, serverMatchedIds: [])
        state.commitLanding(outerIndex: 0, messageId: 1, inner: nil)

        XCTAssertEqual(state.resultsSummary, "1/5000+")
    }

    func testResultsSummaryReportsNoResultsForAQueryThatFoundNothing() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [])
        state.applyFindResult(total: 0, capped: false, serverMatchedIds: [])

        XCTAssertEqual(state.resultsSummary, "No results")
    }

    func testResultsSummaryIsNilForAnEmptyQuery() async {
        let state = TranscriptSearchState()
        state.query = ""
        XCTAssertNil(state.resultsSummary)
    }

    /// While a request is in flight, a stale "No results" would misreport as a real answer
    /// nothing has actually searched yet.
    func testResultsSummaryIsNilWhileLoading() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.beginFind(instantMatchedIds: [])
        XCTAssertNil(state.resultsSummary)
    }
}
