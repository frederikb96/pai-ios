import XCTest

@testable import PAIKit

/// Covers `RowDelta.compute` in isolation — the diff `TranscriptCollectionView` feeds straight
/// into `UICollectionView.performBatchUpdates`, so a misclassification here does not fail loudly;
/// it tells UIKit new content landed at the wrong end of the list.
final class RowDeltaTests: XCTestCase {

    /// The common case: new SSE content arrives at the bottom, ids ascending. Must classify as
    /// `.appended`, not `.prepended` — the two are easy to swap since both branches only differ
    /// by which end of `new` is compared to `old`, and a swap still balances the item count
    /// `performBatchUpdates` checks, so nothing else catches it.
    func testMessagesArrivingAtTheBottomClassifyAsAppended() {
        let delta = RowDelta.compute(old: [1, 2, 3], new: [1, 2, 3, 4, 5])
        XCTAssertEqual(delta, .appended(count: 2))
    }

    /// The other common case: paging in older history at the top. Must classify as `.prepended`,
    /// not `.appended`.
    func testOlderHistoryLoadedAtTheTopClassifiesAsPrepended() {
        let delta = RowDelta.compute(old: [1, 2, 3], new: [-1, 0, 1, 2, 3])
        XCTAssertEqual(delta, .prepended(count: 2))
    }

    func testIdenticalListsAreUnchanged() {
        XCTAssertEqual(RowDelta.compute(old: [1, 2, 3], new: [1, 2, 3]), .unchanged)
    }

    /// The shape sending a message makes: a bubble stands in for the unconfirmed send at the
    /// tail, then the server's own row replaces it. Everything above is untouched, so this must
    /// not degrade to `.replaced` — that means a full reload, and a reload throws away the
    /// anchor holding the reader's place. Sending is the most frequent thing anyone does here,
    /// so this is the classification that decides whether the list is calm in normal use.
    func testAPendingBubbleGivingWayToItsServerRowIsATailReplacement() {
        let delta = RowDelta.compute(old: [1, 2, 3, -1], new: [1, 2, 3, 7])
        XCTAssertEqual(delta, .tailReplaced(commonPrefix: 3, removed: 1, inserted: 1))
    }

    /// Two queued sends collapsing into one confirmed row and one still-pending bubble — the
    /// counts have to come from the lists rather than being assumed equal, or the index paths
    /// handed to `performBatchUpdates` name rows that do not exist.
    func testATailReplacementCountsBothSidesIndependently() {
        let delta = RowDelta.compute(old: [1, -1, -2], new: [1, 7, 8, -1])
        XCTAssertEqual(delta, .tailReplaced(commonPrefix: 1, removed: 2, inserted: 3))
    }

    /// No shared leading run at all — a different session's window, or an eviction that took the
    /// first row with it. There is no anchor to preserve, so a full reload is the honest answer.
    func testAWindowSharingNoLeadingRunFallsBackToReplaced() {
        let delta = RowDelta.compute(old: [1, 2, 3], new: [4, 5, 6, 7])
        XCTAssertEqual(delta, .replaced)
    }
}
