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

/// The microphone failing to start on a tap, until the app is restarted, is what a stale engine
/// or a session not yet active looks like. A start retries on a fresh engine instead of
/// reporting the first failure.
@MainActor
final class MicrophoneStartRecoveryTests: XCTestCase {
    private struct NoInput: Error {}

    private final class Log: @unchecked Sendable {
        var events: [String] = []
    }

    func testAStartThatFailsTwiceRecoversOnAFreshEngineAndSucceeds() async throws {
        let log = Log()
        try await MicrophoneStartRecovery.start(
            attempt: { index in
                log.events.append("attempt \(index)")
                if index < 2 { throw NoInput() }
            },
            recover: { index in log.events.append("recover \(index)") },
            sleep: { duration in log.events.append("sleep \(duration.components.attoseconds / 1_000_000_000_000_000)") }
        )
        XCTAssertEqual(
            log.events,
            ["attempt 0", "sleep 100", "recover 1", "attempt 1", "sleep 250", "recover 2", "attempt 2"])
    }

    func testAStartThatNeverWorksFailsAfterTheBudgetWithTheLastError() async {
        let log = Log()
        do {
            try await MicrophoneStartRecovery.start(
                attempt: { index in
                    log.events.append("attempt")
                    throw NoInput()
                },
                recover: { _ in }, sleep: { _ in })
            XCTFail("expected the start to fail")
        } catch {
            XCTAssertTrue(error is NoInput)
        }
        XCTAssertEqual(log.events.count, 1 + MicrophoneStartRecovery.retryDelaysMs.count)
    }

    func testAStartThatWorksAtOnceNeitherWaitsNorRecovers() async throws {
        let log = Log()
        try await MicrophoneStartRecovery.start(
            attempt: { _ in log.events.append("attempt") }, recover: { _ in log.events.append("recover") },
            sleep: { _ in log.events.append("sleep") })
        XCTAssertEqual(log.events, ["attempt"])
    }
}

/// The call's audio and the dictation capture share this start. An engine that went stale
/// stays stale however often it is started; only a fresh one starts.
@MainActor
final class RecoverableAudioInputTests: XCTestCase {
    private struct StaleInput: Error {}

    private final class StaleEngine: RecoverableAudioInput {
        var isFresh = false
        var starts = 0
        var failures: [Int] = []

        func startOnce() throws {
            starts += 1
            guard isFresh else { throw StaleInput() }
        }

        func rebuildEngine() { isFresh = true }
    }

    func testAStaleEngineIsReplacedBeforeTheRetryThatStartsIt() async throws {
        let engine = StaleEngine()
        var prepared = 0
        try await MicrophoneStartRecovery.start(
            engine, prepareRetry: { prepared += 1 }, onFailure: { index, _ in engine.failures.append(index) },
            sleep: { _ in })
        XCTAssertEqual(engine.starts, 2)
        XCTAssertEqual(engine.failures, [0])
        XCTAssertEqual(prepared, 1)
    }
}
