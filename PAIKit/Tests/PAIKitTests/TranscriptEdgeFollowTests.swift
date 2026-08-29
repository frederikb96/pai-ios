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

        latch.recordDistanceFromBottom(30)  // < pinThreshold(70), > repinThreshold(4)

        XCTAssertFalse(latch.isPinned, "a mid-range distance should not have re-armed the latch")
    }

    func testOnlyComingWithinTheRepinThresholdReArms() {
        var latch = EdgeFollowLatch()
        latch.recordScrollAway()

        latch.recordDistanceFromBottom(EdgeFollowLatch.repinThreshold)

        XCTAssertTrue(latch.isPinned)
    }

    /// Growth alone (content appended while the reader is scrolled up) must never re-pin — only
    /// an actual approach to the bottom should. A sample reporting the SAME distance twice must
    /// not accidentally look like "coming closer".
    func testAlreadyPinnedIgnoresFurtherDistanceSamples() {
        var latch = EdgeFollowLatch()
        latch.recordDistanceFromBottom(500)
        XCTAssertTrue(latch.isPinned, "growth while pinned must never unpin it")
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
