import XCTest

@testable import PAIKit

/// A server that holds a take the way the contract describes: a seal creates it, uploads fill
/// `received`, `missing` is what is left, and the take resolves once nothing is missing. Failures
/// are scripted per call so a test can stand in for an outage the way it happens — the request
/// never answered — rather than as a tidy refusal.
private final class FakeTakeServer: VoiceTakeAPI, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: Int?
    private var received: [SampleRange] = []
    private var state: VoiceTakeState = .open
    private var resolvesAfterPolls: Int
    let text: String
    var failUploads: [PaiError] = []
    var failSeal: [PaiError] = []
    private(set) var uploads: [SampleRange] = []
    private(set) var seals: [VoiceTakeSeal] = []

    init(received: [SampleRange] = [], text: String, resolvesAfterPolls: Int = 1) {
        self.received = received
        self.text = text
        self.resolvesAfterPolls = resolvesAfterPolls
    }

    private func snapshot() -> VoiceTake {
        let missing =
            captured.map { TranscriptLedger.uncoveredRanges(in: [0..<$0], covered: received) } ?? []
        return VoiceTake(
            takeId: "t1", mode: .batch, state: state, draftKey: "s1", capturedSamples: captured,
            received: received, missing: state == .open ? [] : missing, text: state == .done ? text : nil,
            ended: state == .done ? .committed : nil, createdAt: "2026-10-20T10:00:00.000000+00:00")
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    func getVoiceTake(takeId: String) async throws -> VoiceTake {
        locked {
            if state == .sealed,
                TranscriptLedger.uncoveredRanges(in: [0..<(captured ?? 0)], covered: received)
                    .isEmpty
            {
                state = .resolving
            } else if state == .resolving {
                resolvesAfterPolls -= 1
                if resolvesAfterPolls <= 0 { state = .done }
            }
            return snapshot()
        }
    }

    func sealVoiceTake(takeId: String, seal: VoiceTakeSeal) async throws -> VoiceTake {
        try locked {
            seals.append(seal)
            if !failSeal.isEmpty { throw failSeal.removeFirst() }
            if let captured, captured != seal.capturedSamples {
                throw PaiError.detail("seal_conflict", statusCode: 409)
            }
            captured = seal.capturedSamples
            if state == .open { state = .sealed }
            return snapshot()
        }
    }

    func uploadVoiceTakeAudio(takeId: String, range: SampleRange, wav: Data, device: String?) async throws
        -> VoiceTake
    {
        try locked {
            uploads.append(range)
            if !failUploads.isEmpty { throw failUploads.removeFirst() }
            received = TranscriptLedger.merge(received + [range])
            return snapshot()
        }
    }
}

/// The take's recording on disk: silence of whatever length is asked for, up to `samples`.
private struct FakeRecording: TakeAudioReader {
    let samples: Int

    func readSamples(id: String, range: WavByteRange) async throws -> Data {
        let available = max(0, min(range.length, samples * 2 + WavHeaderReader.headerByteCount - range.offset))
        return Data(count: available)
    }
}

final class ServerTakeTests: XCTestCase {
    private static let rate = 16_000

    private func resolve(_ server: FakeTakeServer, captured: Int, recorded: Int? = nil) async
        -> OwedTakeDriver.Outcome
    {
        await OwedTakeDriver.resolve(
            takeId: "t1", seal: VoiceTakeSeal(mode: .batch, capturedSamples: captured, draftKey: "s1"),
            sampleRate: Self.rate, recordedSamples: recorded ?? captured, api: server,
            audioReader: FakeRecording(samples: recorded ?? captured), sleep: { _ in await Task.yield() })
    }

    /// The take the app was killed in: the socket delivered its first ten seconds, the rest only
    /// exists in the file. Resumed with nothing but the ledger, it is sealed, exactly what the
    /// server lists as missing goes up — in pieces small enough for a poor link, retried through
    /// an outage — and the result is read once the server has it.
    func testAnOwedTakeIsSealedFilledFromTheRecordingAndResolved() async {
        let server = FakeTakeServer(received: [0..<160_000], text: "the whole hike", resolvesAfterPolls: 2)
        server.failUploads = [
            PaiError.transport("The network connection was lost."), PaiError.http(statusCode: 503, reason: "down"),
        ]
        let outcome = await resolve(server, captured: 1_600_000)

        guard case let .done(take) = outcome else { return XCTFail("expected done, got \(outcome)") }
        XCTAssertEqual(take.text, "the whole hike")
        XCTAssertEqual(server.seals.map(\.capturedSamples), [1_600_000])
        XCTAssertEqual(
            Set(server.uploads), [160_000..<1_120_000, 1_120_000..<1_600_000],
            "only what was missing, in pieces of at most a minute")
        XCTAssertTrue(server.uploads.allSatisfy { $0.count <= OwedTakeDriver.uploadPieceSeconds * Self.rate })
        XCTAssertEqual(server.uploads.count, 4, "both outage failures were retried")
    }

    /// A refusal no retry changes stops the driver instead of looping; it is reported, and the
    /// take stays owed for the next resume.
    func testARefusedUploadStopsInsteadOfRetrying() async {
        let server = FakeTakeServer(text: "never")
        server.failUploads = [PaiError.detail("audio_length_mismatch", statusCode: 422)]
        let outcome = await resolve(server, captured: 32_000)
        guard case .stuck = outcome else { return XCTFail("expected stuck, got \(outcome)") }
        XCTAssertEqual(server.uploads.count, 1)
    }

    /// The server sealed an untouched take itself at a different length: its own record decides
    /// what is missing, rather than the client's seal being retried forever.
    func testASealConflictFallsBackToTheServersRecord() async {
        let server = FakeTakeServer(text: "from the server")
        _ = try? await server.sealVoiceTake(takeId: "t1", seal: VoiceTakeSeal(mode: .batch, capturedSamples: 16_000))
        let outcome = await resolve(server, captured: 32_000)
        guard case let .done(take) = outcome else { return XCTFail("expected done, got \(outcome)") }
        XCTAssertEqual(take.capturedSamples, 16_000)
        XCTAssertEqual(server.uploads, [0..<16_000])
    }

    /// Asked for audio this device does not hold, the driver says so rather than uploading a
    /// short file the server would refuse.
    func testMissingAudioBeyondTheRecordingIsReportedNotUploaded() async {
        let server = FakeTakeServer(text: "x")
        let outcome = await resolve(server, captured: 32_000, recorded: 16_000)
        guard case .stuck = outcome else { return XCTFail("expected stuck, got \(outcome)") }
        XCTAssertTrue(server.uploads.isEmpty)
    }

    // MARK: - Held send split

    /// What the server composes from `before`, the take's text and `after` must read exactly like
    /// the composer did when the take's words are final — the contract's composition rule, run
    /// against the split for the shapes a composer is really in.
    func testTheSplitRecomposesToWhatTheComposerShowed() throws {
        func compose(_ before: String, _ text: String, _ after: String) -> String {
            [before, text.isEmpty ? "" : "stt-rec: \(text)", after].filter { !$0.isEmpty }.joined(separator: " ")
        }
        let cases: [(composer: String, words: String)] = [
            ("fix the bug stt-rec: and add a test", "and add a test"),
            ("stt-rec: hello thanks", "hello"),
            ("stt-rec: hello", "hello"),
            ("first stt-rec: same words then stt-rec: same words", "same words"),
        ]
        for (composer, words) in cases {
            let split = try XCTUnwrap(HeldTakeSplit.split(composerText: composer, insertedText: "stt-rec: \(words)"))
            XCTAssertEqual(compose(split.before, words, split.after), composer)
        }
        XCTAssertEqual(
            HeldTakeSplit.split(
                composerText: "first stt-rec: same words then stt-rec: same words", insertedText: "stt-rec: same words")?
                .before, "first stt-rec: same words then", "the take's own words are the last ones it wrote")
    }

    /// Words edited or deleted since they were written: nothing to wait on — never a split that
    /// would drop what was typed. A batch take writes nothing while recording, so its words go
    /// after everything.
    func testTheSplitRefusesEditedWordsAndPutsABatchTakeLast() {
        XCTAssertNil(HeldTakeSplit.split(composerText: "stt-rec: hello world", insertedText: "stt-rec: hullo"))
        let batch = HeldTakeSplit.split(composerText: "  check this  ", insertedText: nil)
        XCTAssertEqual(batch?.before, "check this")
        XCTAssertEqual(batch?.after, "")
    }

    // MARK: - Healing the result

    func testAResultReplacesTheTakesWordsAppendsWhenTheyAreGoneAndLeavesExactWordsAlone() {
        XCTAssertEqual(
            TakeResultHeal.apply(
                currentDraftText: "pre stt-rec: half the sen tail", previousInsertedText: "stt-rec: half the sen",
                takeText: "half the sentence"),
            "pre stt-rec: half the sentence tail")
        XCTAssertEqual(
            TakeResultHeal.apply(currentDraftText: "typed", previousInsertedText: nil, takeText: "batch words"),
            "typed stt-rec: batch words")
        XCTAssertNil(
            TakeResultHeal.apply(
                currentDraftText: "stt-rec: all here", previousInsertedText: "stt-rec: all here", takeText: "all here"))
        XCTAssertNil(TakeResultHeal.apply(currentDraftText: "x", previousInsertedText: nil, takeText: "  "))
    }

    // MARK: - Which take a send waits on

    func testASendWaitsOnTheNewestOwedTakeWhoseWordsItCarries() {
        func owed(_ id: String, _ mode: VoiceSttMode, inserted: String? = nil, held: String? = nil, key: String = "s1")
            -> OwedTakeSummary
        {
            OwedTakeSummary(
                takeId: id, draftKey: key,
                serverTake: PendingServerTake(
                    mode: mode, capturedSamples: 16_000, insertedText: inserted, heldClientMessageId: held))
        }
        let takes = [
            owed("100", .live, inserted: "stt-rec: gone"),
            owed("200", .live, inserted: "stt-rec: still here"),
            owed("300", .batch, held: "already-carried"),
            owed("400", .batch, key: "other"),
        ]
        XCTAssertEqual(
            OwedTakeSummary.heldSendCandidate(among: takes, draftKey: "s1", composerText: "stt-rec: still here")?
                .takeId, "200")
        XCTAssertNil(OwedTakeSummary.heldSendCandidate(among: takes, draftKey: "s1", composerText: "nothing of it"))
        XCTAssertEqual(
            OwedTakeSummary.heldSendCandidate(
                among: takes + [owed("500", .batch)], draftKey: "s1", composerText: "")?.takeId, "500")
    }

    // MARK: - Wire shapes

    /// A held row on the session's pending list says why it has not gone yet, inside the bubble's
    /// own text; an ordinary row and a released one read as they are.
    @MainActor
    func testAHeldPendingSendSaysItWaitsOnTheDictation() async throws {
        let json = #"[{"id":1,"text":"look at this","held":true,"take_id":"t1"},{"id":2,"text":"plain"}]"#
        let sends = try JSONDecoder().decode([PendingSend].self, from: Data(json.utf8))
        XCTAssertEqual(sends.map(\.takeId), ["t1", nil])
        XCTAssertTrue(TranscriptStore.bubbleText(for: sends[0]).hasPrefix("look at this\n\n"))
        XCTAssertNotEqual(TranscriptStore.bubbleText(for: sends[0]), "look at this")
        XCTAssertEqual(TranscriptStore.bubbleText(for: sends[1]), "plain")
    }

    /// Ledgers written before takes lived on the server still open, as takes with no server
    /// record — the legacy path, never an owed take sealed at launch.
    func testALedgerFromBeforeServerTakesStillDecodes() throws {
        let old = TranscriptLedger(takeId: "1", mode: .microphone, sampleRate: 16_000, draftKey: "s1", preText: "")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["serverTake"] = nil
        let decoded = try JSONDecoder().decode(
            TranscriptLedger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.serverTake)

        let owed = old.withServerTake(PendingServerTake(mode: .batch, capturedSamples: 10, withheld: [2..<4]))
        let roundTripped = try JSONDecoder().decode(TranscriptLedger.self, from: JSONEncoder().encode(owed))
        XCTAssertEqual(roundTripped.serverTake?.withheld, [2..<4])
        XCTAssertEqual(roundTripped.serverTake?.isOwed, true)
    }
}
