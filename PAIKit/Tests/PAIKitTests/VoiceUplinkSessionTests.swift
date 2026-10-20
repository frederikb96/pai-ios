import XCTest

@testable import PAIKit

/// A fake `VoiceSocketTransportProtocol` a test can feed frames into and read sent frames back
/// out of — an actor because `send`/`receive` are called from whichever isolation context
/// `VoiceUplinkSession`'s own tasks run on, and this needs to be safe to call from more than one
/// at once.
private actor FakeVoiceSocketTransport: VoiceSocketTransportProtocol {
    private(set) var sentFrames: [VoiceUpFrame] = []
    private(set) var sentAudioFrames: [Data] = []
    private var toReceive: [VoiceSocketMessage] = []
    private var pendingReceives: [CheckedContinuation<VoiceSocketMessage, Error>] = []

    func connect(url: URL) async throws {}

    func send(_ frame: VoiceUpFrame) async throws {
        sentFrames.append(frame)
    }

    func sendAudio(_ data: Data) async throws {
        sentAudioFrames.append(data)
    }

    /// Delivers whatever `enqueue(_:)` has queued, in order — once exhausted, waits forever
    /// rather than throwing, matching a real connection that has nothing further to say. The test
    /// ends (and the continuation is simply never resumed) before that matters.
    func receive() async throws -> VoiceSocketMessage {
        if !toReceive.isEmpty {
            return toReceive.removeFirst()
        }
        return try await withCheckedThrowingContinuation { pendingReceives.append($0) }
    }

    func close(code: Int, reason: String?) async {}

    func enqueue(_ message: VoiceSocketMessage) {
        if let continuation = pendingReceives.first {
            pendingReceives.removeFirst()
            continuation.resume(returning: message)
        } else {
            toReceive.append(message)
        }
    }
}

/// A clock that advances itself by exactly what it is asked to sleep for, rather than actually
/// waiting — what lets a test exercise `VoiceUplinkSession.finishingDeadlineSeconds` without
/// costing eight real seconds of wall clock.
private final class FakeClockAndSleep: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 0)

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Only the finishing wait's short polls advance time. The liveness watchdog sleeps for its
    /// whole timeout on the same clock, and letting that jump the clock too would trip it before
    /// `ready` is even processed — a reconnect mid-test that has nothing to do with the deadline
    /// under test. Its sleep therefore never ends on its own; cancelling the watchdog ends it.
    func sleep(_ duration: Duration) async {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard seconds < 12 else {
            try? await Task.sleep(for: .seconds(3600))
            return
        }
        advance(by: seconds)
    }

    /// Plain, non-`async` — `NSLock.lock()`/`unlock()` are unavailable to call directly from an
    /// `async` context.
    private func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

@MainActor
final class VoiceUplinkSessionTests: XCTestCase {

    /// Polls rather than sleeping — see `DraftStoreTests`'s identical helper.
    private func waitUntil(timeout: TimeInterval = 2, _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition(), Date() < deadline {
            await Task.yield()
        }
    }

    /// A test that calls `session.stop()` purely as cleanup, with no interest in the wait itself,
    /// should enqueue a `take_done` for the current take right before it — resolving the wait via
    /// the real receipt path rather than needing the whole `finishingDeadlineSeconds` to pass (or
    /// a fake clock fast enough to reach it, which would just as fast-forward the watchdog and
    /// reconnect backoff every other test here relies on running at real speed).
    private func stopAfterTakeDone(_ session: VoiceUplinkSession, transport: FakeVoiceSocketTransport, takeId: String)
        async
    {
        await transport.enqueue(.control(.takeDone(takeId: takeId, finalSeq: 0, ended: "committed")))
        await session.stop()
    }

    private func makeSession(transport: FakeVoiceSocketTransport) -> VoiceUplinkSession {
        VoiceUplinkSession(
            dependencies: VoiceUplinkDependencies(
                makeTransport: { transport },
                socketURL: { URL(string: "wss://pai.example.com/api/voice/socket")! },
                authToken: { "token" }
            ))
    }

    /// The bug this whole test exists to catch: a take that never sends `gate open` is a take the
    /// backend's `DraftRegionSink` never calls `start_take()` for, so every word transcribed from
    /// it is silently dropped — the very first `ready`, on a brand-new connection with nothing
    /// captured yet, MUST still open the gate, not just a reconnect that finds something already
    /// in flight.
    func testTheFirstReadyOnABrandNewConnectionOpensTheGate() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )

        await waitUntil { await transport.sentFrames.count >= 2 }
        let frames = await transport.sentFrames
        guard case .gate(let open, let reason, let takeId, _, _) = frames.last else {
            return XCTFail("expected a gate frame, got \(String(describing: frames.last))")
        }
        XCTAssertTrue(open)
        XCTAssertEqual(reason, "button")
        XCTAssertEqual(takeId, "take-1", "the take's own id must ride the very first gate open")

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    /// A resend of `gate open` past the resume grace window (a fresh bus mid-take, `ready.resumed
    /// == false`) MUST carry the same `take_id` again — drafts v2 writes no server-side region for
    /// a dictating client to collide with, so re-sending the id is what keeps the take
    /// addressable across the reconnect at all (wire contract §3, R4). Verified safe against the
    /// backend's own test before this changed; see the design report this run followed.
    func testASecondGateOpenWithinTheSameTakeRepeatsTheTakeId() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        // `resumed: false` a second time is what a reconnect past the grace window answers with —
        // a genuinely fresh bus, whatever the resume token happens to do.
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r2", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 3 }

        let frames = await transport.sentFrames
        guard case .gate(_, _, let secondTakeId, _, _) = frames.last else {
            return XCTFail("expected a second gate frame, got \(String(describing: frames.last))")
        }
        XCTAssertEqual(secondTakeId, "take-1", "a reopen within the same take must still carry its own id")

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    // MARK: - Silence gate accounting

    /// A stop that drops the kept pre-roll as silence settles it too: the ring will never be
    /// sent, so leaving it unsettled would hand a second of silence to the upload at every stop.
    /// While withholding, the ring is claimed only after that. The closing gate is the seal: it
    /// states the take's length and the withheld stretch, so the server never asks for it.
    func testASilentStopSettlesThePreRollAndSealsTheWithheldStretch() async {
        let transport = FakeVoiceSocketTransport()
        let session = VoiceUplinkSession(
            dependencies: VoiceUplinkDependencies(
                makeTransport: { transport },
                socketURL: { URL(string: "wss://pai.example.com/api/voice/socket")! },
                authToken: { "token" },
                silenceGate: { .standard }
            ))
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: true))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }
        func samples(amplitude: Int16) -> [Int16] {
            (0..<1600).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
        }
        // 3 s of speech-level audio, then quiet: withholding begins at 8 s (128_000 samples).
        for index in 0..<100 {
            await session.ingestAudioChunk(
                pcm16le: samples(amplitude: index < 30 ? 328 : 6), at: index * 1600)
        }
        XCTAssertEqual(session.capturedUpTo, 160_000)
        await transport.enqueue(.control(.ack(throughSeq: 79)))
        await waitUntil { session.acknowledgedRanges.first?.lowerBound == 0 }
        XCTAssertEqual(
            session.acknowledgedRanges, [0..<144_000],
            "the ring is still to be sent, so it is not claimed while withholding")

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        XCTAssertEqual(session.acknowledgedRanges, [0..<160_000])
        let seals = await transport.sentFrames.compactMap { frame -> (Int?, [SampleRange]?)? in
            guard case let .gate(false, _, _, captured, withheld) = frame else { return nil }
            return (captured, withheld)
        }
        XCTAssertEqual(seals.count, 1)
        XCTAssertEqual(seals.first?.0, 160_000)
        XCTAssertEqual(seals.first?.1, [128_000..<160_000])
        _ = await startTask.value
    }

    // MARK: - Live transcript assembly

    /// A partial replaces whatever partial preceded it; a committed segment appends and clears
    /// the partial — the "revisions included" behaviour the wire contract describes.
    func testPartialReplacesAndCommitAppendsAndClearsIt() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        await transport.enqueue(
            .control(.transcript(takeId: "take-1", seq: 0, isFinal: false, text: "hello wor", endSample: nil)))
        await waitUntil { await session.currentPartial == "hello wor" }

        await transport.enqueue(
            .control(.transcript(takeId: "take-1", seq: 1, isFinal: false, text: "hello world", endSample: nil)))
        await waitUntil { await session.currentPartial == "hello world" }
        XCTAssertEqual(session.committedText, "", "a partial must never be committed on its own")

        await transport.enqueue(
            .control(
                .transcript(takeId: "take-1", seq: 2, isFinal: true, text: "hello world", endSample: 16000)))
        await waitUntil { await session.committedText == "hello world" }
        XCTAssertEqual(session.currentPartial, "", "the partial clears the instant its words are committed")
        XCTAssertEqual(session.composedText, "hello world")

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    /// Positions are take-absolute across a fresh bus: the server's `end_sample` continues the
    /// take's own numbering, so it is used exactly as it arrives. A segment that lands after the
    /// reconnect for a stretch spoken before it — a resolver's piece — still sorts in spoken order,
    /// which shifting it by any per-bus base would break.
    func testEndSampleIsTakeAbsoluteAcrossAFreshBus() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        await transport.enqueue(
            .control(.transcript(takeId: "take-1", seq: 0, isFinal: true, text: "hello", endSample: 16_000)))
        await waitUntil { await session.committedText == "hello" }

        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r2", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 3 }

        await transport.enqueue(
            .control(.transcript(takeId: "take-1", seq: 0, isFinal: true, text: "world", endSample: 40_000)))
        await waitUntil { await session.committedText == "hello world" }
        await transport.enqueue(
            .control(.transcript(takeId: "take-1", seq: 1, isFinal: true, text: "first", endSample: 8_000)))
        await waitUntil { await session.committedText == "first hello world" }
        XCTAssertEqual(session.committedLiveText.map(\.endSample), [8_000, 16_000, 40_000])

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    /// A frame naming another take — the previous take's tail on a bus this one reused — never
    /// lands in this take's text.
    func testAFrameForAnotherTakeIsDropped() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-2") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }
        await transport.enqueue(
            .control(.transcript(takeId: "take-1", seq: 0, isFinal: true, text: "old tail", endSample: 1000)))
        await transport.enqueue(
            .control(.transcript(takeId: "take-2", seq: 1, isFinal: true, text: "new", endSample: 2000)))
        await waitUntil { await session.committedText == "new" }
        XCTAssertEqual(session.committedText, "new")
        await stopAfterTakeDone(session, transport: transport, takeId: "take-2")
        _ = await startTask.value
    }

    // MARK: - Outage buffer

    /// Thirty seconds captured with no connection: only the newest twenty stay in memory and go
    /// up when the socket comes back; the older ten are left unacknowledged, below the frontier
    /// the socket can still deliver — a gap to upload from the file, not a backlog in memory.
    func testAnOutageQueuesAtMostTwentySecondsAndLeavesTheRestAsAGap() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await waitUntil { await session.state == .connecting }
        let chunk = [Int16](repeating: 7, count: 1600)
        for index in 0..<300 {
            await session.ingestAudioChunk(pcm16le: chunk, at: index * 1600)
        }
        XCTAssertEqual(session.capturedUpTo, 480_000)
        XCTAssertEqual(session.uplinkFrontier, 160_000, "everything before the newest 20 s is out of the queue")

        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentAudioFrames.count >= 200 }
        let sent = await transport.sentAudioFrames
        XCTAssertEqual(sent.count, 200)
        XCTAssertEqual(Self.offsets(of: sent).first, 160_000)

        await transport.enqueue(.control(.ack(throughSeq: 199)))
        await waitUntil { await !session.acknowledgedRanges.isEmpty }
        XCTAssertEqual(session.acknowledgedRanges, [160_000..<480_000])
        XCTAssertEqual(session.uplinkFrontier, 480_000)

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    // MARK: - Stop sequence (R1–R5)

    /// The ordinary stop waits for `take_done` before tearing the socket down — `bye` must not go
    /// out before the receipt arrives.
    func testStopWaitsForTakeDoneBeforeClosing() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        let stopTask = Task { await session.stop() }
        await waitUntil {
            await transport.sentFrames.contains { if case .gate(false, _, _, _, _) = $0 { true } else { false } }
        }
        // Give the stop every chance to (wrongly) race ahead to `bye` before the receipt arrives.
        for _ in 0..<20 { await Task.yield() }
        var frames = await transport.sentFrames
        XCTAssertFalse(
            frames.contains { if case .bye = $0 { true } else { false } }, "bye sent before take_done arrived")

        await transport.enqueue(.control(.takeDone(takeId: "take-1", finalSeq: 0, ended: "committed")))
        await stopTask.value
        _ = await startTask.value

        frames = await transport.sentFrames
        XCTAssertTrue(frames.contains { if case .bye = $0 { true } else { false } }, "bye must follow the receipt")
    }

    /// The deadline is what ends the wait when no `take_done` ever arrives — proved against a
    /// fake clock that advances by exactly what each sleep asked for, never by waiting out real
    /// seconds.
    func testStopGivesUpAfterTheDeadlineWithNoTakeDone() async {
        let transport = FakeVoiceSocketTransport()
        let clock = FakeClockAndSleep()
        let session = VoiceUplinkSession(
            dependencies: VoiceUplinkDependencies(
                makeTransport: { transport },
                socketURL: { URL(string: "wss://pai.example.com/api/voice/socket")! },
                authToken: { "token" },
                now: { clock.now() },
                sleep: { await clock.sleep($0) }
            ))
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        await session.stop()
        _ = await startTask.value

        let frames = await transport.sentFrames
        XCTAssertTrue(frames.contains { if case .bye = $0 { true } else { false } })
    }

    /// Leaving or sending during Finishing ends the wait at once and abandons nothing: the only
    /// closing gate is the ordinary one, which already carried the seal.
    func testStopWaitingEndsTheWaitWithoutAbandoningTheTake() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }
        await session.ingestAudioChunk(pcm16le: [1, 2, 3, 4], at: 0)

        let stopTask = Task { await session.stop() }
        await waitUntil {
            await transport.sentFrames.contains { if case .gate(false, _, _, _, _) = $0 { true } else { false } }
        }
        let asked = Date()
        session.stopWaiting()
        await stopTask.value
        _ = await startTask.value

        XCTAssertLessThan(Date().timeIntervalSince(asked), 5, "the wait ends when asked, not at its deadline")
        XCTAssertEqual(session.state, .idle)
        let closes = await transport.sentFrames.compactMap { frame -> (String, String?, Int?)? in
            guard case let .gate(false, reason, takeId, captured, _) = frame else { return nil }
            return (reason, takeId, captured)
        }
        XCTAssertEqual(closes.map(\.0), ["button"], "nothing may abandon the take")
        XCTAssertEqual(closes.first?.1, "take-1")
        XCTAssertEqual(closes.first?.2, 4)
    }

    /// A batch take says so on `hello`, and its stop waits for the seal to be stored
    /// (`take_state` past `open`), never for a `take_done` that may be minutes away.
    func testABatchTakeAnnouncesItselfAndItsStopWaitsForTheStoredSeal() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1", sttMode: .batch) }
        await waitUntil { await !transport.sentFrames.isEmpty }
        guard case let .hello(_, _, _, _, draftKey, _, _, sttMode, standalone) = await transport.sentFrames.first
        else { return XCTFail("expected hello first") }
        XCTAssertEqual(draftKey, "session-1")
        XCTAssertEqual(sttMode, .batch)
        XCTAssertFalse(standalone)
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        let stopTask = Task { await session.stop() }
        await waitUntil {
            await transport.sentFrames.contains { if case .gate(false, _, _, _, _) = $0 { true } else { false } }
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(session.state, .stopping, "still waiting for the seal to be stored")
        await transport.enqueue(
            .control(.takeState(takeId: "take-1", state: .sealed, capturedSamples: 0, missing: [])))
        await stopTask.value
        _ = await startTask.value
        XCTAssertEqual(session.state, .idle)
    }

    /// The frames the server reads a take's identity and seal from, as JSON.
    func testHelloAndTheClosingGateCarryTheTakeFields() throws {
        let hello = try VoiceUpFrame.hello(
            transport: "ios", caps: VoiceSocketCapabilities(), auth: "t", resumeToken: nil, draftKey: nil,
            sttMode: .batch, standalone: true
        ).encoded()
        let helloObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(hello.utf8)) as? [String: Any])
        XCTAssertEqual(helloObject["stt_mode"] as? String, "batch")
        XCTAssertEqual(helloObject["standalone"] as? Bool, true)
        XCTAssertNil(helloObject["draft_key"])

        let close = try VoiceUpFrame.gate(
            open: false, reason: "button", takeId: "take-1", capturedSamples: 48_000, withheld: [16_000..<32_000]
        ).encoded()
        let closeObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(close.utf8)) as? [String: Any])
        XCTAssertEqual(closeObject["take_id"] as? String, "take-1")
        XCTAssertEqual(closeObject["captured_samples"] as? Int, 48_000)
        XCTAssertEqual(closeObject["withheld"] as? [[Int]], [[16_000, 32_000]])
    }

    /// Stopping when there was never a live connection (still `.connecting`, nothing acked yet)
    /// must not hang waiting for a receipt nothing will ever send.
    func testStopWithNoLiveConnectionExitsImmediately() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        // Never enqueue a `ready` — the session stays `.connecting` the whole time.
        await waitUntil { await session.state == .connecting }

        await session.stop()
        _ = await startTask.value

        XCTAssertEqual(session.state, .idle)
    }

    /// `ready.resumed == true` must NOT resend `gate open` — the bus/engine never detached, so
    /// re-opening it would be wrong, not just redundant.
    func testAResumedReadyDoesNotResendGateOpen() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: true, sessionId: nil, silenceAllowed: false)))
        // Nothing further should ever be sent for this `ready` — wait past a couple of scheduler
        // turns rather than a fixed frame count, since the assertion is an absence.
        for _ in 0..<20 { await Task.yield() }

        let frames = await transport.sentFrames
        XCTAssertEqual(frames.count, 2, "a resumed ready must not send a second gate frame")

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    /// The wire `seq` counter restarts at 0 on EVERY `ready`, including a resumed one — the
    /// bug a rotated resume token could previously hide, since `isFreshBus` used to be inferred
    /// from token identity rather than read off `resumed` directly.
    func testSeqRestartsAtZeroOnAResumedReadyToo() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeSession(transport: transport)

        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: false))
        )
        await waitUntil { await transport.sentFrames.count >= 2 }

        await session.ingestAudioChunk(pcm16le: [1, 2, 3], at: 0)
        await waitUntil { await transport.sentAudioFrames.count >= 1 }

        // A rotated token on the SAME bus — the case the old token-comparison inference would
        // have misread as a fresh bus. `resumed: true` must not add a second gate frame.
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r2", busOwner: .transcription, resumed: true, sessionId: nil, silenceAllowed: false)))
        for _ in 0..<20 { await Task.yield() }
        let framesAfterResume = await transport.sentFrames
        XCTAssertEqual(framesAfterResume.count, 2, "a resumed ready must not send a second gate frame")

        await session.ingestAudioChunk(pcm16le: [4, 5, 6], at: 3)
        await waitUntil { await transport.sentAudioFrames.count >= 2 }

        let expected = VoiceSocketProtocol.packUplinkAudio(seq: 0, sampleOffset: 3, pcm16le: [4, 5, 6])
        let sentAudio = await transport.sentAudioFrames
        XCTAssertEqual(
            sentAudio.last, expected,
            "seq must restart at 0 on the new socket even though the bus resumed")

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    // MARK: - Silence gate

    private static func gateFrame(db: Double) -> [Int16] {
        let amplitude = Int16((32768 * pow(10, db / 20)).rounded())
        return (0..<1600).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private static func offsets(of audio: [Data]) -> [Int] {
        audio.map { data in
            let bytes = [UInt8](data.prefix(8))
            return Int(bytes[4]) << 24 | Int(bytes[5]) << 16 | Int(bytes[6]) << 8 | Int(bytes[7])
        }
    }

    private func makeGatedSession(transport: FakeVoiceSocketTransport) -> VoiceUplinkSession {
        VoiceUplinkSession(
            dependencies: VoiceUplinkDependencies(
                makeTransport: { transport },
                socketURL: { URL(string: "wss://pai.example.com/api/voice/socket")! },
                authToken: { "token" },
                silenceGate: { .standard }
            ))
    }

    /// A quiet stretch on a bus that allows it: audio stops leaving, the backend is told where,
    /// and the first speech after it arrives with the second before it — never resending what
    /// went up before the silence.
    func testAQuietStretchIsWithheldAndSpeechResumesWithItsPreroll() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeGatedSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: true)))
        await waitUntil { session.state == .recording }

        var offset = 0
        for db in Array(repeating: -40.0, count: 30) + Array(repeating: -75.0, count: 90) {
            await session.ingestAudioChunk(pcm16le: Self.gateFrame(db: db), at: offset)
            offset += 1600
        }
        let duringQuiet = await transport.sentAudioFrames
        XCTAssertEqual(duringQuiet.count, 80)
        XCTAssertTrue(session.isWithholding)
        let silences = await transport.sentFrames.compactMap { frame -> Int? in
            if case let .silence(atSample) = frame { return atSample }
            return nil
        }
        XCTAssertEqual(silences, [128_000])

        await session.ingestAudioChunk(pcm16le: Self.gateFrame(db: -40), at: offset)
        let resumed = Self.offsets(of: Array(await transport.sentAudioFrames.dropFirst(80)))
        XCTAssertEqual(resumed.first, 177_600)
        XCTAssertEqual(resumed.last, 192_000)
        XCTAssertFalse(session.isWithholding)

        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }

    /// The hello says the gate is on, so the backend suspends the timers that would otherwise
    /// read a quiet client as an idle one.
    func testHelloDeclaresTheGate() async {
        let transport = FakeVoiceSocketTransport()
        let session = makeGatedSession(transport: transport)
        let startTask = Task { await session.start(draftKey: "session-1", takeId: "take-1") }
        await waitUntil { await !transport.sentFrames.isEmpty }
        guard case let .hello(_, caps, _, _, _, _, _, _, _) = await transport.sentFrames.first else {
            return XCTFail("expected hello first")
        }
        XCTAssertTrue(caps.silenceGate)
        await transport.enqueue(
            .control(
                .ready(
                    resumeToken: "r1", busOwner: .transcription, resumed: false, sessionId: nil, silenceAllowed: true)))
        await waitUntil { session.state == .recording }
        await stopAfterTakeDone(session, transport: transport, takeId: "take-1")
        _ = await startTask.value
    }
}
