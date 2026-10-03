import XCTest

@testable import PAIKit

final class MicrophoneRouteGuardTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    /// A Bluetooth headset reconfigures the engine right after capture starts, sometimes with the
    /// input reported as a different port than before the handshake.
    func testAChangeDuringStartUpRestartsCaptureAndRebaselines() {
        var guardian = MicrophoneRouteGuard(input: "builtin", startedAt: start)
        XCTAssertEqual(
            guardian.engineReconfigured(input: "earbuds-hfp", now: start.addingTimeInterval(0.4)), .restartCapture)
        XCTAssertEqual(
            guardian.engineReconfigured(input: "earbuds-hfp", now: start.addingTimeInterval(30)), .restartCapture)
    }

    func testAFormatChangeOnTheSameDeviceAfterSettlingRestartsCapture() {
        var guardian = MicrophoneRouteGuard(input: "earbuds", startedAt: start)
        XCTAssertEqual(
            guardian.engineReconfigured(input: "earbuds", now: start.addingTimeInterval(20)), .restartCapture)
    }

    func testADifferentDeviceAfterSettlingEndsTheRun() {
        var guardian = MicrophoneRouteGuard(input: "earbuds", startedAt: start)
        XCTAssertEqual(guardian.engineReconfigured(input: "builtin", now: start.addingTimeInterval(20)), .endRun)
    }

    func testNoInputAfterSettlingEndsTheRun() {
        var guardian = MicrophoneRouteGuard(input: nil, startedAt: start)
        XCTAssertEqual(guardian.engineReconfigured(input: nil, now: start.addingTimeInterval(20)), .endRun)
    }
}
