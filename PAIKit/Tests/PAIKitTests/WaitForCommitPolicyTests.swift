import XCTest

@testable import PAIKit

final class WaitForCommitPolicyTests: XCTestCase {

    func testContinuesWaitingWhileUnderTimeoutAndCommitNotYetReceived() {
        XCTAssertTrue(WaitForCommitPolicy.shouldContinueWaiting(elapsedMs: 0, commitReceived: false))
        XCTAssertTrue(
            WaitForCommitPolicy.shouldContinueWaiting(
                elapsedMs: WaitForCommitPolicy.timeoutMs - 1, commitReceived: false
            )
        )
    }

    func testStopsWaitingOnceTheCommitArrivesEvenWellUnderTimeout() {
        XCTAssertFalse(WaitForCommitPolicy.shouldContinueWaiting(elapsedMs: 100, commitReceived: true))
    }

    func testStopsWaitingAtTheTimeoutRegardlessOfCommitState() {
        XCTAssertFalse(
            WaitForCommitPolicy.shouldContinueWaiting(
                elapsedMs: WaitForCommitPolicy.timeoutMs, commitReceived: false
            )
        )
    }
}

final class VoiceRecordingResultTests: XCTestCase {

    func testEmptyTranscriptStaysEmptyRatherThanABarePrefix() {
        let result = VoiceRecordingResult(
            text: "", endedBy: .silence, durationMs: 500, mutedMs: 0, sampleRate: 24000, narrowband: false
        )
        XCTAssertEqual(result.prefixedText, "")
    }

    func testNonEmptyTranscriptGetsThePrefixExactlyOnce() {
        let result = VoiceRecordingResult(
            text: "hello world", endedBy: .user, durationMs: 3000, mutedMs: 0, sampleRate: 24000,
            narrowband: false
        )
        XCTAssertEqual(result.prefixedText, "stt-rec: hello world")
    }
}
