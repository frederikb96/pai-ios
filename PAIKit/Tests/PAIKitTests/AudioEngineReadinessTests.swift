import XCTest

@testable import PAIKit

/// A cue played after a take has ended, with the audio session already deactivated, finds the
/// engine stopped and its restart refused. `AVAudioPlayerNode.play()` on that stopped engine
/// raises an Objective-C exception and kills the app; these pin that the caller is told not to
/// play in exactly that situation.
final class AudioEngineReadinessTests: XCTestCase {
    private struct StartRefused: Error {}

    func testRefusedStartReportsNotRunningAndNamesTheFailure() {
        var failures: [any Error] = []
        let ready = AudioEngineReadiness.ensureRunning(
            isRunning: { false }, start: { throw StartRefused() }, onStartFailure: { failures.append($0) })
        XCTAssertFalse(ready)
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first is StartRefused)
    }

    func testStartThatReturnsWithoutRunningIsNotTrusted() {
        var starts = 0
        let ready = AudioEngineReadiness.ensureRunning(isRunning: { false }, start: { starts += 1 })
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(ready)
    }

    func testStoppedEngineThatStartsIsReady() {
        var running = false
        let ready = AudioEngineReadiness.ensureRunning(isRunning: { running }, start: { running = true })
        XCTAssertTrue(ready)
    }

    func testRunningEngineIsNotRestarted() {
        var starts = 0
        let ready = AudioEngineReadiness.ensureRunning(isRunning: { true }, start: { starts += 1 })
        XCTAssertTrue(ready)
        XCTAssertEqual(starts, 0)
    }

    func testInputWithoutARouteIsUnusable() {
        XCTAssertFalse(AudioEngineReadiness.isUsableInputFormat(sampleRate: 0, channelCount: 1))
        XCTAssertFalse(AudioEngineReadiness.isUsableInputFormat(sampleRate: 48_000, channelCount: 0))
        XCTAssertTrue(AudioEngineReadiness.isUsableInputFormat(sampleRate: 48_000, channelCount: 1))
    }
}
