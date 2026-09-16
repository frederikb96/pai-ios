import XCTest

@testable import PAIKit

/// Runs the pipeline against ElevenLabs' real services rather than a scripted fake — everything
/// else in this package proves the pipeline's *logic*; this proves the assumptions that logic
/// depends on (a real socket drops and reconnects the way `VoiceRecordingSession` expects, a real
/// batch call returns word timestamps `SeamMerge` can place, a real TTS socket streams audio and
/// tolerates a context close) still hold against the actual service.
///
/// Every method starts with `requireLiveElevenLabsApiKey()`, which skips (not fails) unless
/// `PAI_LIVE_ELEVENLABS=1` is set and `ELEVENLABS_API_KEY` is present in the process environment —
/// read only there, never logged, never compared to anything, never printed. Every URL or error
/// text this file ever puts into an assertion message is routed through `ElevenLabsLiveRedacting`
/// first, proven correct on its own in `ElevenLabsLiveRedactingTests`, which runs unconditionally.
@MainActor
final class ElevenLabsLiveTests: XCTestCase {
    private static let sampleRate = 16000

    /// A thrown `URLSession` error carries the failing URL, and a socket URL carries its
    /// single-use token as a query parameter — so every failure this class records is redacted,
    /// not only the messages the tests compose themselves.
    override func recordFailure(
        withDescription description: String, inFile filePath: String, atLine lineNumber: Int, expected: Bool
    ) {
        super.recordFailure(
            withDescription: ElevenLabsLiveRedacting.redact(description), inFile: filePath, atLine: lineNumber,
            expected: expected)
    }
    private static let chunkSize = 1600

    private static func tokenKind(for purpose: VoiceTokenPurpose) -> LiveElevenLabsClient.TokenKind {
        switch purpose {
        case .realtime: return .realtime
        case .batch: return .batch
        case .tts: return .tts
        }
    }

    private static func chunked(_ samples: [Int16]) -> [[Int16]] {
        stride(from: 0, to: samples.count, by: chunkSize).map {
            Array(samples[$0..<min($0 + chunkSize, samples.count)])
        }
    }

    // MARK: The flagship — a real drop, a real reconnect, a real batch backfill

    /// Drives a real `VoiceRecordingSession` over a real connection through exactly the sequence
    /// the design exists for: speech, then — far enough back that it can never be covered by the
    /// reconnect's own burst — a forced drop partway through a second utterance, a real reconnect
    /// carrying `previous_text` the way `VoiceRecordingSession` actually sends it, and a real
    /// `BatchBackfiller` call filling the resulting gap. Asserts every word of both utterances
    /// comes out of the merged transcript exactly once, in order — the property `SeamMerge` exists
    /// to guarantee, checked here against a real round trip rather than a scripted one.
    ///
    /// The silence padding between the two utterances is what makes the first one's recovery
    /// genuinely depend on the batch endpoint: `VoiceRecordingSession`'s burst tail only ever
    /// replays the most recent `burstTailSeconds` of *sent* audio, so once more than that much has
    /// been sent since utterance A finished, A can never be bursted back — its recovery has no
    /// path except the batch pass this test then drives for real.
    func testFlakyConnectionRecoversEveryWordThroughReconnectAndRealBatchBackfill() async throws {
        let apiKey = try requireLiveElevenLabsApiKey()
        try requireLiveWebSockets()
        let sampleRate = Self.sampleRate

        let textA = "Testing recovery of the earliest words spoken."
        let textB = "Confirming every later word survives the drop as well."
        let samplesA = try await LiveSpeechFixtureCache.shared.speech(textA, apiKey: apiKey)
        let samplesB = try await LiveSpeechFixtureCache.shared.speech(textB, apiKey: apiKey)
        XCTAssertFalse(samplesA.isEmpty)
        XCTAssertFalse(samplesB.isEmpty)

        let silenceSeconds = VoiceRecordingSession.burstTailSeconds + 4
        let silenceSamples = [Int16](repeating: 0, count: silenceSeconds * sampleRate)

        let chunksA = Self.chunked(samplesA)
        let chunksSilence = Self.chunked(silenceSamples)
        let chunksB = Self.chunked(samplesB)
        let dropIndex = chunksB.count / 2
        let chunksBBeforeDrop = Array(chunksB[..<dropIndex])
        let chunksBAfterDrop = Array(chunksB[dropIndex...])
        // The forced drop lands after exactly this many uplink frames — everything before it goes
        // out over the first connection; nothing after it does.
        let dropAfterSendCount = chunksA.count + chunksSilence.count + chunksBBeforeDrop.count

        let attemptCounter = LiveConnectionAttemptCounter()
        let dependencies = VoiceRecordingDependencies(
            mintToken: { purpose in
                try await LiveElevenLabsClient.mintToken(Self.tokenKind(for: purpose), apiKey: apiKey)
            },
            makeRealtimeTransport: {
                // Only the very first connection is armed to drop — every reconnect after it must
                // be allowed to run to completion, or the take would never finish.
                let attempt = attemptCounter.next()
                return LiveDropRealtimeTransport(dropAfterSendCount: attempt == 1 ? dropAfterSendCount : nil)
            },
            settings: { VoiceSettings(sttLanguage: .en) },
            health: { .stable }
        )
        let session = VoiceRecordingSession(dependencies: dependencies)

        var fullAudio: [Int16] = []
        func feed(_ chunk: [Int16]) async {
            let offset = fullAudio.count
            fullAudio.append(contentsOf: chunk)
            await session.ingestAudioChunk(pcm16le: chunk, at: offset)
            try? await Task.sleep(nanoseconds: UInt64(VoiceRealtimeProtocol.chunkIntervalMs) * 1_000_000)
        }

        await session.start(hardwareSampleRate: sampleRate)
        let connected = await waitUntilLive(timeoutSeconds: 20) { await session.state == .recording }
        guard connected else {
            XCTFail("start failed: \(String(describing: await session.lastStartFailure))")
            return
        }

        for chunk in chunksA { await feed(chunk) }
        for chunk in chunksSilence { await feed(chunk) }
        for chunk in chunksBBeforeDrop { await feed(chunk) }

        let sawDrop = await waitUntilLive(timeoutSeconds: 10) { await session.state == .reconnecting }
        XCTAssertTrue(sawDrop, "the forced close should have moved the session out of .recording")

        // Capture keeps running through the outage, exactly as it would on a real phone — the app
        // never learns or cares that the socket is down until this point.
        for chunk in chunksBAfterDrop { await feed(chunk) }

        let reconnected = await waitUntilLive(timeoutSeconds: 30) { await session.state == .recording }
        XCTAssertTrue(reconnected, "a real reconnect against the live service should complete well inside 30s")

        await session.stop(reason: .user)
        let idled = await waitUntilLive(timeoutSeconds: 10) { await session.state == .idle }
        XCTAssertTrue(idled)

        let capturedUpTo = session.capturedUpTo
        let committedSegments = session.committedSegments
        let liveLedger = TranscriptLedger(
            takeId: "live-flaky-take", mode: .microphone, sampleRate: sampleRate, draftKey: "session", preText: "",
            segments: committedSegments
        )
        let gaps = liveLedger.derivedGaps(capturedUpTo: capturedUpTo)
        XCTAssertFalse(
            gaps.isEmpty,
            "utterance A should have fallen outside the burst tail and left a real gap for the batch pass — "
                + "if this is empty, BatchBackfiller was never actually exercised"
        )

        let reader = LiveInMemoryTakeAudioReader(pcm16leData: packPcm16LE(fullAudio))
        let requests = BackfillPlanner.plan(
            gaps: gaps, sampleRate: sampleRate, capturedUpTo: capturedUpTo, health: .stable
        )
        XCTAssertFalse(requests.isEmpty)

        var batchSegments: [Segment] = []
        for request in requests {
            let outcome = await BatchBackfiller.run(
                request, sampleRate: sampleRate, language: .en, audioReader: reader, takeId: "live-flaky-take",
                transcribe: { wav, language in
                    try await Self.realBatchTranscribe(wav: wav, language: language, apiKey: apiKey)
                }
            )
            switch outcome {
            case let .segment(segment): batchSegments.append(segment)
            case .noSpeechDetected: XCTFail("expected the batch endpoint to hear utterance A's speech")
            case let .failed(error): XCTFail("batch backfill failed: \(ElevenLabsLiveRedacting.redact(error))")
            }
        }
        XCTAssertFalse(
            batchSegments.isEmpty, "the batch pass must actually have produced a segment for this to be a real proof"
        )

        let merged = SeamMerge.merge(committedSegments + batchSegments)
        let assembled = merged.sorted { $0.range.lowerBound < $1.range.lowerBound }.map(\.text).joined(separator: " ")
        let oracle = normalizedWords(textA) + normalizedWords(textB)
        assertWordsAppearInOrderExactlyOnce(oracle: oracle, actual: normalizedWords(assembled))
    }

    /// Shared by the flagship test and `testL5…` below — a real `batch_scribe` mint followed by a
    /// real `VoiceBatchTranscriber` call, converting the returned connection-relative seconds into
    /// take-relative `Word`s the way `BatchBackfiller.run` expects from its `transcribe` closure.
    private static func realBatchTranscribe(
        wav: Data, language: VoiceSettings.Language, apiKey: String
    ) async throws -> (text: String, words: [Word]) {
        let token = try await LiveElevenLabsClient.mintToken(.batch, apiKey: apiKey)
        let result = try await VoiceBatchTranscriber().transcribeWithWordTimestamps(
            wav: wav, token: token.token, language: language
        )
        switch result {
        case let .words(text, words):
            let asWords = words.map { word in
                Word(
                    range: Int(word.start * Double(sampleRate))..<Int(word.end * Double(sampleRate)), text: word.text,
                    logprob: word.logprob
                )
            }
            return (text: text, words: asWords)
        case .noSpeechDetected:
            return (text: "", words: [])
        case let .failed(error):
            throw error
        }
    }

    // MARK: L2 — both committed-message variants carry matching text

    /// A raw realtime connection (no `VoiceRecordingSession` in the loop) proving the assumption
    /// its decoder relies on: with `include_timestamps=true`, `committed_transcript` and
    /// `committed_transcript_with_timestamps` both arrive for the same segment, with identical
    /// text — which is exactly why the session only ever *acts* on the timestamped one and uses
    /// the plain one solely to clear the partial, rather than appending both and duplicating text.
    func testCommittedTranscriptAndItsTimestampedTwinCarryMatchingText() async throws {
        let apiKey = try requireLiveElevenLabsApiKey()
        try requireLiveWebSockets()
        let sampleRate = Self.sampleRate
        let text = "A short phrase for checking both commit messages."
        let samples = try await LiveSpeechFixtureCache.shared.speech(text, apiKey: apiKey)
        XCTAssertFalse(samples.isEmpty)

        let token = try await LiveElevenLabsClient.mintToken(.realtime, apiKey: apiKey)
        guard
            let url = VoiceRealtimeProtocol.connectionURL(token: token.token, sampleRate: sampleRate, language: .en)
        else {
            XCTFail("could not build the connection URL")
            return
        }
        let transport = URLSessionVoiceRealtimeTransport()
        try await transport.connect(url: url)

        let log = LiveMessageLog<RealtimeDownlinkMessage>()
        let receiveTask = Task {
            while !Task.isCancelled {
                guard let raw = try? await transport.receive() else { return }
                if let message = RealtimeDownlinkMessage.decode(raw) { await log.append(message) }
            }
        }
        defer { receiveTask.cancel() }

        let started = await waitUntilLive(timeoutSeconds: 15) { (await log.messages).contains(.sessionStarted) }
        XCTAssertTrue(started, "no session_started within 15s")

        for chunk in Self.chunked(samples) {
            let frame = RealtimeUplinkChunk(
                audioBase64: RealtimeUplinkChunk.audioBase64(fromPCM16LE: chunk), commit: false, sampleRate: sampleRate
            )
            try await transport.send(text: String(decoding: try frame.encoded(), as: UTF8.self))
            try? await Task.sleep(nanoseconds: UInt64(VoiceRealtimeProtocol.chunkIntervalMs) * 1_000_000)
        }
        let commitFrame = RealtimeUplinkChunk.commitFrame(sampleRate: sampleRate)
        try await transport.send(text: String(decoding: try commitFrame.encoded(), as: UTF8.self))

        let gotBoth = await waitUntilLive(timeoutSeconds: 15) {
            let messages = await log.messages
            let hasPlain = messages.contains {
                if case .committedTranscript = $0 { return true }; return false
            }
            let hasTimestamped = messages.contains {
                if case .committedTranscriptWithWords = $0 { return true }; return false
            }
            return hasPlain && hasTimestamped
        }
        await transport.close(code: 1000, reason: nil)
        XCTAssertTrue(gotBoth, "expected both committed_transcript and committed_transcript_with_timestamps")

        let messages = await log.messages
        let nonEmptyPlainTexts = messages.compactMap { message -> String? in
            guard case let .committedTranscript(text) = message, !text.isEmpty else { return nil }
            return text
        }
        let nonEmptyTimestampedTexts = messages.compactMap { message -> String? in
            guard case let .committedTranscriptWithWords(text, _) = message, !text.isEmpty else { return nil }
            return text
        }
        XCTAssertFalse(nonEmptyPlainTexts.isEmpty)
        XCTAssertEqual(
            nonEmptyPlainTexts, nonEmptyTimestampedTexts,
            "the two message variants must carry identical text for the same segment"
        )
    }

    // MARK: L5 — the batch endpoint, word timestamps, an exact byte range

    /// One clip, one request whose `audioRange` covers exactly the clip's own bytes — proving the
    /// real batch endpoint returns word timestamps for the range asked, and that
    /// `BatchBackfiller.run` correctly shifts them into take-relative offsets (here, offset zero,
    /// so shifting by the request's start is a no-op the test would notice if it were wrong).
    func testBatchEndpointReturnsWordTimestampsForAnExactByteRange() async throws {
        let apiKey = try requireLiveElevenLabsApiKey()
        let sampleRate = Self.sampleRate
        let text = "Exact byte range transcription check."
        let samples = try await LiveSpeechFixtureCache.shared.speech(text, apiKey: apiKey)
        XCTAssertFalse(samples.isEmpty)

        let range: SampleRange = 0..<samples.count
        let reader = LiveInMemoryTakeAudioReader(pcm16leData: packPcm16LE(samples))
        let request = BackfillPlanner.Request(range: range, audioRange: range, gapRanges: [range])

        let outcome = await BatchBackfiller.run(
            request, sampleRate: sampleRate, language: .en, audioReader: reader, takeId: "l5-take",
            transcribe: { wav, language in
                try await Self.realBatchTranscribe(wav: wav, language: language, apiKey: apiKey)
            }
        )

        guard case let .segment(segment) = outcome else {
            XCTFail("expected a segment from a real batch call, got \(outcome)")
            return
        }
        XCTAssertEqual(segment.range, range)
        let words = segment.words ?? []
        XCTAssertFalse(words.isEmpty, "word timestamps must actually have come back")
        for word in words {
            XCTAssertLessThanOrEqual(word.range.lowerBound, word.range.upperBound)
            XCTAssertTrue(
                word.range.lowerBound >= 0 && word.range.upperBound <= samples.count,
                "every word must land inside the requested byte range"
            )
        }
        assertWordsAppearInOrderExactlyOnce(oracle: normalizedWords(text), actual: normalizedWords(segment.text))
    }

    // MARK: L6 — the TTS multi-context socket

    /// Opens the multi-context TTS socket with a real `tts_websocket` token, streams one reply
    /// into one context, waits for real audio, then closes the context and the socket — the same
    /// sequence `SpeechOutputSession` drives in the app, proven here against the live service since
    /// nothing in this package otherwise ever opens a real connection to it.
    func testTtsWebsocketOpensAContextStreamsAudioAndClosesIt() async throws {
        let apiKey = try requireLiveElevenLabsApiKey()
        try requireLiveWebSockets()
        let voiceId = try await LiveSpeechFixtureCache.shared.voice(apiKey: apiKey)
        let token = try await LiveElevenLabsClient.mintToken(.tts, apiKey: apiKey)
        guard let url = VoiceTtsProtocol.connectionURL(voiceId: voiceId, token: token.token) else {
            XCTFail("could not build the TTS connection URL")
            return
        }
        let transport = URLSessionVoiceTtsTransport()
        try await transport.connect(url: url)

        let log = LiveMessageLog<TtsDownlinkMessage>()
        let receiveTask = Task {
            while !Task.isCancelled {
                guard let raw = try? await transport.receive() else { return }
                if let message = TtsDownlinkMessage.decode(raw) { await log.append(message) }
            }
        }
        defer { receiveTask.cancel() }

        let contextId = "live-test-context"
        try await transport.send(
            text: String(
                decoding: try TtsUplinkMessage.initializeContext(contextId: contextId).encoded(), as: UTF8.self)
        )
        try await transport.send(
            text: String(
                decoding: try TtsUplinkMessage.sendText(
                    contextId: contextId, text: "A short reply for the live pipeline test.", flush: true
                ).encoded(), as: UTF8.self
            )
        )

        let gotAudio = await waitUntilLive(timeoutSeconds: 15) {
            (await log.messages).contains {
                if case .audio = $0 { return true }; return false
            }
        }
        XCTAssertTrue(gotAudio, "expected at least one audio chunk back on the context")

        // Closing costs almost nothing here — by the time a short reply's first chunk has arrived,
        // ElevenLabs has typically already generated most or all of its audio — but it must still
        // succeed without error, exactly as `SpeechOutputSession`'s own "skip" path requires.
        try await transport.send(
            text: String(decoding: try TtsUplinkMessage.closeContext(contextId: contextId).encoded(), as: UTF8.self)
        )
        try await transport.send(text: String(decoding: try TtsUplinkMessage.closeSocket.encoded(), as: UTF8.self))
        await transport.close(code: 1000, reason: nil)

        let audioMessages = (await log.messages).compactMap { message -> String? in
            guard case let .audio(_, base64) = message else { return nil }
            return base64
        }
        XCTAssertFalse(audioMessages.isEmpty)
        let totalSamples = audioMessages.reduce(0) { $0 + (VoiceTtsProtocol.pcm16Samples(fromBase64: $1)?.count ?? 0) }
        XCTAssertGreaterThan(totalSamples, 0, "the decoded audio must actually contain samples")
    }
}
