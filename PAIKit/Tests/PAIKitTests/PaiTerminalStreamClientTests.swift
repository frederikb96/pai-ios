import XCTest
@testable import PAIKit

/// Exercises `PaiTerminalStreamClient.parseFrame` directly — the pure part of the terminal
/// stream — without the connection/reconnect machinery around it.
final class PaiTerminalStreamClientTests: XCTestCase {

    func testWellFormedFrameReadsDataAndLiveFlag() {
        let (chunk, live) = PaiTerminalStreamClient.parseFrame(#"{"data":"hello","live":false}"#)
        XCTAssertEqual(chunk, "hello")
        XCTAssertFalse(live)
    }

    /// The one rule the source calls out explicitly: an absent `live` field must default to
    /// `true`, not `false` — a stuck "scrolled back" banner nothing can clear is worse than
    /// briefly claiming to be live.
    func testAbsentLiveFlagDefaultsTrue() {
        let (_, live) = PaiTerminalStreamClient.parseFrame(#"{"data":"hello"}"#)
        XCTAssertTrue(live)
    }

    /// Same rule, the other way a value can be missing: present but the wrong JSON type.
    func testMalformedLiveFlagDefaultsTrueRatherThanFailingTheFrame() {
        let (chunk, live) = PaiTerminalStreamClient.parseFrame(#"{"data":"hello","live":"nope"}"#)
        XCTAssertEqual(chunk, "hello")
        XCTAssertTrue(live)
    }

    func testNonJsonBodyIsTreatedAsTheChunkItself() {
        let (chunk, live) = PaiTerminalStreamClient.parseFrame("raw terminal bytes")
        XCTAssertEqual(chunk, "raw terminal bytes")
        XCTAssertTrue(live)
    }

    /// Valid JSON that simply isn't this shape (no `data` key) falls back the same way as
    /// non-JSON input, rather than throwing the frame away.
    func testJsonWithoutDataKeyFallsBackToRawChunk() {
        let raw = #"{"unrelated":"value"}"#
        let (chunk, live) = PaiTerminalStreamClient.parseFrame(raw)
        XCTAssertEqual(chunk, raw)
        XCTAssertTrue(live)
    }

    // MARK: - sseDataValue

    func testSseDataValueStripsExactlyOneLeadingSpace() {
        XCTAssertEqual(PaiTerminalStreamClient.sseDataValue(from: " hello"), "hello")
    }

    /// Terminal output legitimately carries meaningful leading/trailing whitespace (indentation,
    /// padding); only the single SSE-framing space is protocol, not data.
    func testSseDataValuePreservesInteriorAndTrailingWhitespace() {
        let chunk = PaiTerminalStreamClient.sseDataValue(from: "  indented line  ")
        XCTAssertEqual(chunk, " indented line  ")
    }

    func testSseDataValueLeavesLineWithoutLeadingSpaceUntouched() {
        let chunk = PaiTerminalStreamClient.sseDataValue(from: "no-leading-space")
        XCTAssertEqual(chunk, "no-leading-space")
    }

    // MARK: - shouldReconnectAfterStreamEnded

    /// The regression this guards: a `streamTask` cancelled by `connect()`/`disconnect()` racing
    /// a still-running connection must not also schedule its own reconnect on top of whichever
    /// call cancelled it — that was the source of the doubled reconnect.
    func testShouldReconnectAfterStreamEndedIsFalseWhenCancelled() {
        let shouldReconnect = PaiTerminalStreamClient.shouldReconnectAfterStreamEnded(
            cancelled: true, stopped: false
        )
        XCTAssertFalse(shouldReconnect)
    }

    func testShouldReconnectAfterStreamEndedIsFalseWhenStopped() {
        let shouldReconnect = PaiTerminalStreamClient.shouldReconnectAfterStreamEnded(
            cancelled: false, stopped: true
        )
        XCTAssertFalse(shouldReconnect)
    }

    func testShouldReconnectAfterStreamEndedIsTrueOtherwise() {
        let shouldReconnect = PaiTerminalStreamClient.shouldReconnectAfterStreamEnded(
            cancelled: false, stopped: false
        )
        XCTAssertTrue(shouldReconnect)
    }
}
