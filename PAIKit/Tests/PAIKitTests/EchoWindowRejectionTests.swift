import XCTest

@testable import PAIKit

final class EchoWindowRejectionTests: XCTestCase {

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testOverlappingWindowWithMatchingTextIsEcho() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(10)...date(11), commandText: "Kai stop",
            playbackWindows: [(window: date(9)...date(12), text: "If you say Kai stop, I will end the call.")]
        )
        XCTAssertTrue(isEcho)
    }

    /// Freddy genuinely saying a command while the agent happens to be talking must still work —
    /// overlap alone is not echo, or barge-in ("computer skip") could never fire.
    func testOverlappingWindowWithNoTextMatchIsNotEcho() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(10)...date(11), commandText: "Kai stop",
            playbackWindows: [(window: date(9)...date(12), text: "The weather today is sunny and warm.")]
        )
        XCTAssertFalse(isEcho)
    }

    func testMatchingTextWithNoOverlappingWindowIsNotEcho() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(100)...date(101), commandText: "Kai stop",
            playbackWindows: [(window: date(9)...date(12), text: "If you say Kai stop, I will end the call.")]
        )
        XCTAssertFalse(isEcho)
    }

    func testTheComparisonIsCaseInsensitive() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(10)...date(11), commandText: "KAI STOP",
            playbackWindows: [(window: date(9)...date(12), text: "kai stop right there")]
        )
        XCTAssertTrue(isEcho)
    }

    func testAnEmptyCommandTextIsNeverEcho() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(10)...date(11), commandText: "   ",
            playbackWindows: [(window: date(9)...date(12), text: "anything at all")]
        )
        XCTAssertFalse(isEcho)
    }

    func testNoPlaybackWindowsAtAllIsNeverEcho() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(10)...date(11), commandText: "Kai stop", playbackWindows: [])
        XCTAssertFalse(isEcho)
    }

    /// Several replies may have played recently; only the one that actually overlaps and
    /// matches should trigger rejection — a coincidental match somewhere else in history must
    /// not veto a genuine command.
    func testOnlyTheOverlappingEntryIsConsultedAmongSeveral() {
        let isEcho = EchoWindowRejection.isEcho(
            commandWindow: date(50)...date(51), commandText: "Kai stop",
            playbackWindows: [
                (window: date(9)...date(12), text: "Kai stop, an old unrelated reply"),
                (window: date(49)...date(52), text: "the weather is nice today"),
            ]
        )
        XCTAssertFalse(isEcho)
    }
}
