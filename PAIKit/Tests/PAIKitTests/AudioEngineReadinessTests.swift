import XCTest

@testable import PAIKit

/// With no input route (mid route change, during an interruption, in the background without an
/// active session) the input node reports an empty format, and installing a tap on it raises an
/// Objective-C exception that ends the app. Capture must refuse to start instead.
final class AudioEngineReadinessTests: XCTestCase {
    func testInputWithoutARouteIsUnusable() {
        XCTAssertFalse(AudioEngineReadiness.isUsableInputFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(AudioEngineReadiness.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(AudioEngineReadiness.isUsableInputFormat(sampleRate: 48_000, channelCount: 1))
    }
}
