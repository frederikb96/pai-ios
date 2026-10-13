import XCTest

@testable import PAIKit

final class StreamRevivalTests: XCTestCase {

    func testAQuietConnectionIsReplacedOnceItIsOlderThanThePingInterval() {
        XCTAssertTrue(
            StreamRevival.shouldReconnect(
                stopped: false, terminal: false, sinceLastEvent: StreamRevival.idleThreshold + 1, force: false))
    }

    func testAConnectionHearingPingsIsLeftAlone() {
        XCTAssertFalse(
            StreamRevival.shouldReconnect(stopped: false, terminal: false, sinceLastEvent: 16, force: false))
    }

    func testARegainedNetworkReplacesEvenARecentConnection() {
        XCTAssertTrue(StreamRevival.shouldReconnect(stopped: false, terminal: false, sinceLastEvent: 1, force: true))
    }

    func testAStoppedOrFinishedStreamStaysThatWayEvenWhenForced() {
        XCTAssertFalse(StreamRevival.shouldReconnect(stopped: true, terminal: false, sinceLastEvent: 999, force: true))
        XCTAssertFalse(StreamRevival.shouldReconnect(stopped: false, terminal: true, sinceLastEvent: 999, force: true))
    }

    /// The server's ping interval is 15 s; a threshold at or below it would replace healthy
    /// connections on every wake.
    func testTheThresholdSitsAbovetheServersPingInterval() {
        XCTAssertGreaterThan(StreamRevival.idleThreshold, 15)
    }

    func testTheWakeNotificationCarriesWhetherItIsForced() {
        let center = NotificationCenter()
        // `queue: nil` delivers synchronously on the posting thread, so the box is never shared.
        final class Seen: @unchecked Sendable { var values: [Bool] = [] }
        let seen = Seen()
        let token = center.addObserver(forName: StreamWake.name, object: nil, queue: nil) {
            seen.values.append(StreamWake.isForced($0))
        }
        StreamWake.post(force: true, center: center)
        StreamWake.post(force: false, center: center)
        center.removeObserver(token)

        XCTAssertEqual(seen.values, [true, false])
    }
}
