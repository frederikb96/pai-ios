import XCTest

@testable import PAIKit

/// `EdgeFollowLatch` is the one place a "reasonable implementer" collapses two thresholds into
/// one and reintroduces the bug the web spent real time on: a short flick up re-pinning on the
/// very next scroll sample, snapping the view straight back down.
final class TranscriptEdgeFollowTests: XCTestCase {

    func testStartsPinnedByDefault() {
        XCTAssertTrue(EdgeFollowLatch().isPinned)
    }

    func testADeliberateScrollAwayUnpinsRegardlessOfDistance() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()
        XCTAssertFalse(latch.isPinned)
    }

    /// This is the bug the asymmetric thresholds exist to prevent: a distance between the two
    /// thresholds must not re-pin, or a short flick up would be pulled straight back down.
    func testDistanceBetweenTheTwoThresholdsDoesNotRepin() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(30, hasNewer: false)  // < pinThreshold(70), > repinThreshold(4)

        XCTAssertFalse(latch.isPinned, "a mid-range distance should not have re-armed the latch")
    }

    func testOnlyComingWithinTheRepinThresholdReArms() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(EdgeFollowLatch.repinThreshold, hasNewer: false)

        XCTAssertTrue(latch.isPinned)
    }

    /// Growth alone (content appended while the reader is scrolled up) must never re-pin — only
    /// an actual approach to the bottom should. A sample reporting the SAME distance twice must
    /// not accidentally look like "coming closer".
    func testAlreadyPinnedIgnoresFurtherDistanceSamples() {
        var latch = EdgeFollowLatch()
        latch.recordDistanceFromBottom(500, hasNewer: false)
        XCTAssertTrue(latch.isPinned, "growth while pinned must never unpin it")
    }

    /// The bug a notification deep link into old history hit: landing leaves little of the
    /// window's own "after" half loaded, so the distance to the bottom of what is loaded reads
    /// small even though real conversation continues well past it. Without this guard, that
    /// sample re-pins the latch, and every SSE event and newer-page fetch that follows then drags
    /// the reader toward the true tail in steps.
    func testHasNewerBlocksRepinEvenWithinTheThreshold() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(0, hasNewer: true)

        XCTAssertFalse(latch.isPinned, "the bottom of an un-caught-up window must not count as the live edge")
    }

    /// Once paging has caught the window up to the true tail, geometry is trustworthy again.
    func testRepinsNormallyOnceHasNewerClears() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(0, hasNewer: false)

        XCTAssertTrue(latch.isPinned)
    }

    // MARK: - isAtLiveEdge (stateless)

    func testIsAtLiveEdgeIsPureGeometryIndependentOfPinnedState() {
        XCTAssertTrue(EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: EdgeFollowLatch.pinThreshold))
        XCTAssertFalse(EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: EdgeFollowLatch.pinThreshold + 1))
    }

    /// The subtlest distinction in the whole model: a latch that has been deliberately unpinned
    /// can still sit at a position that is geometrically "at the edge" — the two questions must
    /// not be conflated into one flag.
    func testAtLiveEdgeCanDisagreeWithIsPinned() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        XCTAssertFalse(latch.isPinned)
        XCTAssertTrue(
            EdgeFollowLatch.isAtLiveEdge(distanceFromBottom: 0), "geometry alone should still report the edge")
    }
}
