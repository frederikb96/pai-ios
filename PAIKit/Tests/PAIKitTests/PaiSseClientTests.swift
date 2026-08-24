import XCTest
@testable import PAIKit

/// Exercises the pure parts of `PaiSseClient` — SSE data-line framing and the
/// reconnect-after-cancellation rule — without the connection/reconnect machinery around them.
final class PaiSseClientTests: XCTestCase {

    // MARK: - sseDataValue

    func testSseDataValueStripsExactlyOneLeadingSpace() {
        XCTAssertEqual(PaiSseClient.sseDataValue(from: " {\"a\":1}"), "{\"a\":1}")
    }

    func testSseDataValuePreservesInteriorAndTrailingWhitespace() {
        XCTAssertEqual(PaiSseClient.sseDataValue(from: "  {\"a\": 1}  "), " {\"a\": 1}  ")
    }

    func testSseDataValueLeavesLineWithoutLeadingSpaceUntouched() {
        XCTAssertEqual(PaiSseClient.sseDataValue(from: "no-leading-space"), "no-leading-space")
    }

    // MARK: - shouldReconnectAfterStreamEnded

    /// The regression this guards: the watchdog reconnects by cancelling `streamTask`, whose
    /// own `for try await` then unwinds through this same exit path — reacting to that unwind
    /// as a second disconnect scheduled a reconnect on top of the one the watchdog already
    /// started.
    func testShouldReconnectAfterStreamEndedIsFalseWhenCancelled() {
        let shouldReconnect = PaiSseClient.shouldReconnectAfterStreamEnded(
            cancelled: true, terminal: false, stopped: false
        )
        XCTAssertFalse(shouldReconnect)
    }

    func testShouldReconnectAfterStreamEndedIsFalseWhenTerminal() {
        let shouldReconnect = PaiSseClient.shouldReconnectAfterStreamEnded(
            cancelled: false, terminal: true, stopped: false
        )
        XCTAssertFalse(shouldReconnect)
    }

    func testShouldReconnectAfterStreamEndedIsFalseWhenStopped() {
        let shouldReconnect = PaiSseClient.shouldReconnectAfterStreamEnded(
            cancelled: false, terminal: false, stopped: true
        )
        XCTAssertFalse(shouldReconnect)
    }

    func testShouldReconnectAfterStreamEndedIsTrueOtherwise() {
        let shouldReconnect = PaiSseClient.shouldReconnectAfterStreamEnded(
            cancelled: false, terminal: false, stopped: false
        )
        XCTAssertTrue(shouldReconnect)
    }
}
