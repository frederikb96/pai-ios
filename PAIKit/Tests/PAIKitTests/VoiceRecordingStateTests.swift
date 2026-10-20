import XCTest

@testable import PAIKit

/// The microphone level line above the composer is the one continuous proof that a take is still
/// capturing. It must not disappear when the connection comes up or flaps, only when the
/// microphone stops.
final class VoiceRecordingStateTests: XCTestCase {
    func testLevelLineStaysThroughATakeOnAFlakyConnection() {
        let take: [VoiceRecordingState] = [
            .connecting, .recording, .reconnecting, .recording, .paused, .recording, .transcriptionStopped,
        ]
        for state in take {
            XCTAssertTrue(state.showsMicrophoneLevel, "level line hidden while \(state)")
        }
    }

    func testLevelLineHidesOnceTheMicrophoneStops() {
        XCTAssertFalse(VoiceRecordingState.stopping.showsMicrophoneLevel)
        XCTAssertFalse(VoiceRecordingState.idle.showsMicrophoneLevel)
    }
}
