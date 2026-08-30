import Foundation
import XCTest

@testable import PAIKit

/// Every method is `async` even where nothing inside it awaits anything — see
/// `TranscriptStoreTests`'s doc comment for why a `@MainActor` `XCTestCase` needs that on Linux.
@MainActor
final class SearchStateTests: XCTestCase {

    private func hit(messageId: Int, cardIndex: Int = 0, blockIndex: Int = 0, location: Int = 0) -> TranscriptSearchHit
    {
        TranscriptSearchHit(
            messageId: messageId, cardIndex: cardIndex, expandKey: nil, blockIndex: blockIndex,
            range: NSRange(location: location, length: 1))
    }

    func testOpenActivatesSearch() async {
        let state = TranscriptSearchState()
        state.open()
        XCTAssertTrue(state.isActive)
    }

    func testCloseResetsEverythingIncludingTheQuery() async {
        let state = TranscriptSearchState()
        state.open()
        state.query = "needle"
        state.setResults(hits: [hit(messageId: 1)], truncated: true, readerMessageId: nil)
        state.isLoadingFullHistory = true

        state.close()

        XCTAssertFalse(state.isActive)
        XCTAssertEqual(state.query, "")
        XCTAssertEqual(state.hits, [])
        XCTAssertNil(state.activeHitIndex)
        XCTAssertFalse(state.isLoadingFullHistory)
    }

    // MARK: - Starting position: at or after the reader, else the last one before

    func testSetResultsStartsAtTheFirstHitAtOrAfterTheReaderPosition() async {
        let state = TranscriptSearchState()
        let hits = [hit(messageId: 1), hit(messageId: 5), hit(messageId: 9)]
        state.setResults(hits: hits, truncated: false, readerMessageId: 5)
        XCTAssertEqual(state.activeHitIndex, 1)
        XCTAssertEqual(state.currentHit?.messageId, 5)
    }

    /// The reader is past every hit — there is nothing "at or after" them, so search falls back
    /// to the last hit before their position, matching the web's rule exactly.
    func testSetResultsFallsBackToTheLastHitBeforeTheReaderWhenNoneIsAtOrAfter() async {
        let state = TranscriptSearchState()
        let hits = [hit(messageId: 1), hit(messageId: 2)]
        state.setResults(hits: hits, truncated: false, readerMessageId: 100)
        XCTAssertEqual(state.activeHitIndex, 1)
    }

    func testSetResultsStartsAtTheFirstHitWhenNoReaderPositionIsKnown() async {
        let state = TranscriptSearchState()
        let hits = [hit(messageId: 1), hit(messageId: 2)]
        state.setResults(hits: hits, truncated: false, readerMessageId: nil)
        XCTAssertEqual(state.activeHitIndex, 0)
    }

    func testSetResultsWithNoHitsLeavesNoActiveIndex() async {
        let state = TranscriptSearchState()
        state.setResults(hits: [], truncated: false, readerMessageId: 1)
        XCTAssertNil(state.activeHitIndex)
        XCTAssertNil(state.currentHit)
    }

    // MARK: - Stepping

    func testNextWrapsFromTheLastHitBackToTheFirst() async {
        let state = TranscriptSearchState()
        state.setResults(hits: [hit(messageId: 1), hit(messageId: 2)], truncated: false, readerMessageId: 2)
        XCTAssertEqual(state.activeHitIndex, 1)
        state.next()
        XCTAssertEqual(state.activeHitIndex, 0)
    }

    func testPreviousWrapsFromTheFirstHitBackToTheLast() async {
        let state = TranscriptSearchState()
        state.setResults(hits: [hit(messageId: 1), hit(messageId: 2)], truncated: false, readerMessageId: 1)
        XCTAssertEqual(state.activeHitIndex, 0)
        state.previous()
        XCTAssertEqual(state.activeHitIndex, 1)
    }

    func testSteppingWithNoHitsDoesNothing() async {
        let state = TranscriptSearchState()
        state.next()
        XCTAssertNil(state.activeHitIndex)
        state.previous()
        XCTAssertNil(state.activeHitIndex)
    }

    // MARK: - Summary text

    func testResultsSummaryReportsPositionAndTotal() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.setResults(hits: [hit(messageId: 1), hit(messageId: 2)], truncated: false, readerMessageId: 1)
        XCTAssertEqual(state.resultsSummary, "1/2")
    }

    func testResultsSummaryMarksATruncatedCountWithAPlus() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.setResults(hits: [hit(messageId: 1)], truncated: true, readerMessageId: 1)
        XCTAssertEqual(state.resultsSummary, "1/1+")
    }

    func testResultsSummaryReportsNoResultsForAQueryThatFoundNothing() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.setResults(hits: [], truncated: false, readerMessageId: nil)
        XCTAssertEqual(state.resultsSummary, "No results")
    }

    func testResultsSummaryIsNilForAnEmptyQuery() async {
        let state = TranscriptSearchState()
        state.query = ""
        XCTAssertNil(state.resultsSummary)
    }

    /// While a full-history load is filling the window search cannot see yet, a stale "No
    /// results" would misreport as a real answer nothing has actually searched yet.
    func testResultsSummaryIsNilWhileLoadingFullHistory() async {
        let state = TranscriptSearchState()
        state.query = "needle"
        state.isLoadingFullHistory = true
        XCTAssertNil(state.resultsSummary)
    }
}
