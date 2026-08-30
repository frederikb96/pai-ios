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

    /// Neither a clean prefix nor a clean suffix match — an LRU eviction landing mid-window, or
    /// any shape the "contiguous ascending suffix" invariant does not predict. A full reload is
    /// the honest fallback rather than guessing at index paths that might not exist.
    func testAnArbitraryChangeFallsBackToReplaced() {
        let delta = RowDelta.compute(old: [1, 2, 3], new: [1, 2, 4, 5])
        XCTAssertEqual(delta, .replaced)
    }
}
