import XCTest

@testable import PAIKit

/// A scriptable stand-in for the realtime socket, matching `VoiceRecordingSessionTests`' own
/// fake in shape — kept as a separate, file-private copy rather than shared, since the two files
/// script it toward different ends (per-message assertions there, a whole flaky schedule here).
private actor ScheduledFakeTransport: VoiceRealtimeTransport {
    private(set) var sentTexts: [String] = []
    private(set) var connectCallCount = 0
    private var queuedMessages: [String] = []
    private var waitingReceivers: [CheckedContinuation<String, Error>] = []
    private var failed = false

    func connect(url: URL) async throws {
        connectCallCount += 1
        failed = false
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> String {
        if !queuedMessages.isEmpty { return queuedMessages.removeFirst() }
        if failed { throw VoiceTransportError.connectionLost(reason: nil) }
        return try await withCheckedThrowingContinuation { continuation in
            waitingReceivers.append(continuation)
        }
    }

    func close(code: Int, reason: String?) async {
        failReceivers()
    }

    func push(_ text: String) {
        if !waitingReceivers.isEmpty {
            waitingReceivers.removeFirst().resume(returning: text)
        } else {
            queuedMessages.append(text)
        }
    }

    func fail() {
        failed = true
        failReceivers()
    }

    private func failReceivers() {
        let receivers = waitingReceivers
        waitingReceivers = []
        for receiver in receivers {
            receiver.resume(throwing: VoiceTransportError.connectionLost(reason: nil))
        }
    }
}

/// Reads a slice of a synthetic take's audio — backed by one `Data` built once per test, holding
/// every second of the take regardless of what the live socket ever managed to cover, exactly the
/// property a real `-sent.wav` file has (capture never pauses for a connection reason).
private struct FakeTakeAudioReader: TakeAudioReader {
    let sampleData: Data

    func readSamples(id: String, range: WavByteRange) async throws -> Data {
        let start = range.offset - WavHeaderReader.headerByteCount
        let end = start + range.length
        guard start >= 0, end <= sampleData.count, start < end else { return Data() }
        return sampleData.subdata(in: start..<end)
    }
}

/// A single mutable flag a `@Sendable` closure can flip — `runBackfill`'s calls are strictly
/// sequential (each `await`ed before the next begins), so the lack of real synchronization here
/// is safe in practice; `@unchecked` is what lets a plain reference type stand in as the
/// `var` capture a `@Sendable` closure signature otherwise refuses.
private final class PoisonFlag: @unchecked Sendable {
    var remaining: Bool
    init(_ remaining: Bool) { self.remaining = remaining }
}

/// The end-to-end Linux proof: drives `VoiceRecordingSession` through a scripted flaky
/// connection, then runs the surviving gaps through `BackfillPlanner`/`BatchBackfiller`, then
/// `SeamMerge`s live and batch segments together — asserting the final text equals a scripted
/// oracle with zero gaps left, however the schedule scrambled who covered what.
@MainActor
final class FlakyPipelineTests: XCTestCase {

    private let sampleRate = 16000

    // MARK: The synthetic take and its oracle

    /// Every sample in second `N` carries the value `N` (wrapped well inside `Int16`) — the whole
    /// point being that raw PCM bytes alone are enough to reconstruct which second they came
    /// from, which is exactly what the batch stub below needs to answer correctly for whatever
    /// byte range `BatchBackfiller` actually reads, with no side channel.
    private func syntheticSamples(forSecond second: Int) -> [Int16] {
        [Int16](repeating: Int16(second % 30000), count: sampleRate)
    }

    private func oracleWord(forSecond second: Int) -> String { "word\(second)" }

    private func oracleText(totalSeconds: Int) -> String {
        (0..<totalSeconds).map(oracleWord).joined(separator: " ")
    }

    /// The whole take's raw PCM bytes (no WAV header) — what a real `-sent.wav` file holds by the
    /// time the take ends, since capture never stops for a connection reason.
    private func fullTakeSampleData(totalSeconds: Int) -> Data {
        var data = Data()
        for second in 0..<totalSeconds {
            for sample in syntheticSamples(forSecond: second) {
                var little = sample.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// The batch endpoint's stand-in: decodes the WAV it was handed back into per-second words
    /// purely from the sample values `BatchBackfiller` read off disk — the same "no side channel"
    /// property a real transcription would have, since it never sees the take's real offsets.
    /// `static` and `nonisolated` so it captures nothing when handed to a `@Sendable` closure.
    private nonisolated static func batchTranscribe(wav: Data, sampleRate: Int) -> (text: String, words: [Word]) {
        guard WavHeaderReader.parse(wav) != nil, wav.count > WavHeaderReader.headerByteCount else {
            return (text: "", words: [])
        }
        let pcmBytes = [UInt8](wav.suffix(from: WavHeaderReader.headerByteCount))
        var samples: [Int16] = []
        samples.reserveCapacity(pcmBytes.count / 2)
        var index = 0
        while index + 1 < pcmBytes.count {
            let littleEndian = UInt16(pcmBytes[index]) | (UInt16(pcmBytes[index + 1]) << 8)
            samples.append(Int16(bitPattern: littleEndian))
            index += 2
        }
        var words: [Word] = []
        var cursor = 0
        while cursor < samples.count {
            let secondValue = Int(samples[cursor])
            var end = cursor
            while end < samples.count, Int(samples[end]) == secondValue { end += 1 }
            if end - cursor == sampleRate {
                words.append(Word(range: cursor..<end, text: "word\(secondValue)"))
            }
            cursor = end
        }
        return (text: words.map(\.text).joined(separator: " "), words: words)
    }

    // MARK: Driving the live phase

    private func waitUntil(_ condition: () -> Bool, iterations: Int = 20_000) async {
        for _ in 0..<iterations {
            if condition() { return }
            await Task.yield()
        }
    }

    /// Feeds the take second by second, dropping the connection for the scripted windows and
    /// never confirming a live commit for anything captured inside one — exactly what happens to
    /// any stretch older than the 20s burst tail, which every window here exceeds or matches by
    /// construction. Everything outside a window gets an immediate, correctly-addressed
    /// `committed_transcript_with_timestamps` the moment it is sent.
    private func runLivePhase(
        totalSeconds: Int, dropWindows: [(start: Int, duration: Int)]
    ) async -> VoiceRecordingSession {
        let transport = ScheduledFakeTransport()
        let session = VoiceRecordingSession(
            dependencies: VoiceRecordingDependencies(
                mintToken: { _ in VoiceToken(token: "tok", expiresIn: 900) },
                makeRealtimeTransport: { transport },
                settings: { VoiceSettings() },
                sleep: { _ in },
                health: { .stable }
            )
        )
        await session.start(hardwareSampleRate: sampleRate)
        await transport.push(#"{"message_type":"session_started"}"#)
        await waitUntil { session.state == .recording }

        var chunksThisConnection = 0
        for second in 0..<totalSeconds {
            if let window = dropWindows.first(where: { $0.start == second }) {
                for _ in 0..<window.duration {
                    await transport.fail()
                    await waitUntil { session.state == .reconnecting }
                    await transport.push(#"{"message_type":"session_started"}"#)
                    await waitUntil { session.state == .recording }
                }
                chunksThisConnection = 0
            }
            let insideAnyWindow = dropWindows.contains { second >= $0.start && second < $0.start + $0.duration }

            let sentBefore = await transport.sentTexts.count
            await session.ingestAudioChunk(pcm16le: syntheticSamples(forSecond: second), at: second * sampleRate)
            await waitUntil(async: { await transport.sentTexts.count > sentBefore })

            // Every transmitted chunk — committed or not — advances the real session's own
            // `SessionTimeline` by one connection-relative second, so this counter must too, or
            // a later scripted commit's timestamp resolves against the wrong chunk entirely.
            let mySessionRelativeSecond = chunksThisConnection
            chunksThisConnection += 1
            guard !insideAnyWindow else { continue }
            let startSeconds = Double(mySessionRelativeSecond)
            let endSeconds = Double(mySessionRelativeSecond + 1)
            await transport.push(
                #"{"message_type":"committed_transcript_with_timestamps","text":"\#(oracleWord(forSecond: second))","words":[{"text":"\#(oracleWord(forSecond: second))","start":\#(startSeconds),"end":\#(endSeconds),"type":"word"}]}"#
            )
            await waitUntil { session.committedSegments.last?.range.upperBound == (second + 1) * sampleRate }
        }

        await session.stop(reason: .user)
        await waitUntil { session.state == .idle }
        return session
    }

    private func waitUntil(async condition: () async -> Bool, iterations: Int = 20_000) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
    }

    // MARK: Backfilling and assembling

    /// Runs every eligible gap through `BackfillPlanner` + `BatchBackfiller` to completion (a
    /// stable link, so nothing is deferred), returning the `.batch` segments produced.
    /// `poisonFirstAttempt`, when set, makes the very first `BatchBackfiller.run` call fail —
    /// schedule 4's "a drop during the batch upload".
    private func runBackfill(
        gaps: [Gap], capturedUpTo: Int, sampleData: Data, poisonFirstAttempt: Bool
    ) async -> [Segment] {
        let reader = FakeTakeAudioReader(sampleData: sampleData)
        var remainingGaps = gaps
        var segments: [Segment] = []
        let poison = PoisonFlag(poisonFirstAttempt)
        let sampleRate = self.sampleRate

        // Two rounds: the first may fail (schedule 4), a later stable episode always retries.
        for _ in 0..<2 {
            let requests = BackfillPlanner.plan(
                gaps: remainingGaps, sampleRate: sampleRate, capturedUpTo: capturedUpTo, health: .stable
            )
            guard !requests.isEmpty else { break }
            var nextGaps = remainingGaps
            for request in requests {
                let outcome = await BatchBackfiller.run(
                    request, sampleRate: sampleRate, language: .auto, audioReader: reader, takeId: "take",
                    transcribe: { wav, _ in
                        if poison.remaining {
                            poison.remaining = false
                            throw VoiceTransportError.notConnected
                        }
                        return Self.batchTranscribe(wav: wav, sampleRate: sampleRate)
                    }
                )
                switch outcome {
                case let .segment(segment):
                    segments.append(segment)
                    nextGaps.removeAll { request.gapRanges.contains($0.range) }
                case .noSpeechDetected:
                    nextGaps.removeAll { request.gapRanges.contains($0.range) }
                case let .failed(error):
                    for gapRange in request.gapRanges {
                        guard let index = nextGaps.firstIndex(where: { $0.range == gapRange }) else { continue }
                        nextGaps[index] = BackfillPlanner.recordFailure(nextGaps[index], error: error)
                    }
                }
            }
            remainingGaps = nextGaps
        }
        XCTAssertTrue(remainingGaps.isEmpty, "every gap must resolve within two stable episodes in these schedules")
        return segments
    }

    /// One schedule end to end: live phase, then backfill, then `SeamMerge`, asserting the final
    /// text equals the oracle with zero gaps left.
    private func assertScheduleRecoversPerfectly(
        totalSeconds: Int, dropWindows: [(start: Int, duration: Int)], poisonFirstBackfillAttempt: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        let session = await runLivePhase(totalSeconds: totalSeconds, dropWindows: dropWindows)
        let capturedUpTo = session.capturedUpTo
        let liveLedger = TranscriptLedger(
            takeId: "take", mode: .microphone, sampleRate: sampleRate, draftKey: "session", preText: "",
            segments: session.committedSegments
        )
        let gaps = liveLedger.derivedGaps(capturedUpTo: capturedUpTo)

        let sampleData = fullTakeSampleData(totalSeconds: totalSeconds)
        let batchSegments = await runBackfill(
            gaps: gaps, capturedUpTo: capturedUpTo, sampleData: sampleData,
            poisonFirstAttempt: poisonFirstBackfillAttempt
        )

        let merged = SeamMerge.merge(session.committedSegments + batchSegments)
        let finalLedger = TranscriptLedger(
            takeId: "take", mode: .microphone, sampleRate: sampleRate, draftKey: "session", preText: "",
            segments: merged
        )
        XCTAssertTrue(
            finalLedger.derivedGaps(capturedUpTo: capturedUpTo).isEmpty, "zero gaps once backfill has run",
            file: file, line: line
        )

        let assembledText = merged.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(
            separator: " ")
        XCTAssertEqual(assembledText, oracleText(totalSeconds: totalSeconds), file: file, line: line)

        // The sensitivity `SeamMerge` exists to prove: without it, the batch request's own
        // one-second margin re-transcribes words the live path already committed, so a naive
        // concatenation duplicates them and can never equal the oracle — this is what would turn
        // red if `SeamMerge.merge` above were bypassed or broken.
        if !batchSegments.isEmpty {
            let naive =
                (session.committedSegments + batchSegments)
                .sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(separator: " ")
            XCTAssertNotEqual(
                naive, oracleText(totalSeconds: totalSeconds),
                "sanity check: this schedule's margin overlap must be real, or SeamMerge is not actually exercised",
                file: file, line: line
            )
        }
    }

    // MARK: The four schedules

    func testASingleThreeSecondDropRecoversEveryWord() async {
        await assertScheduleRecoversPerfectly(totalSeconds: 10, dropWindows: [(start: 3, duration: 3)])
    }

    /// Far longer than the 20s burst tail — everything in the window is left for the batch pass
    /// entirely, never re-burst through the live socket at all.
    func testANinetySecondOutageRecoversEveryWord() async {
        await assertScheduleRecoversPerfectly(totalSeconds: 150, dropWindows: [(start: 20, duration: 90)])
    }

    /// The worst case named by the design itself: drops every four seconds for three minutes,
    /// then clean — many small gaps, never reaching `.stable` until the flapping stops, all
    /// resolved once it does.
    func testFlappingEveryFourSecondsForThreeMinutesThenCleanRecoversEveryWord() async {
        let dropWindows = stride(from: 3, to: 180, by: 4).map { (start: $0, duration: 1) }
        await assertScheduleRecoversPerfectly(totalSeconds: 190, dropWindows: Array(dropWindows))
    }

    /// A backfill request itself fails mid-upload — the gap must survive that failure with its
    /// attempt count bumped rather than being lost, and a later retry still recovers it.
    func testADropDuringTheBatchUploadStillRecoversOnRetry() async {
        await assertScheduleRecoversPerfectly(
            totalSeconds: 10, dropWindows: [(start: 3, duration: 3)], poisonFirstBackfillAttempt: true
        )
    }
}
