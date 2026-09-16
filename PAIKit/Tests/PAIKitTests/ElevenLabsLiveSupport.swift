import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Everything the live tests share: reading the key, minting a token straight from ElevenLabs
/// (never through pai-cloud — there is no backend in this test), synthesizing and caching the
/// speech fixture, and the small pieces of network plumbing (a message log, a poll loop, a
/// forced-drop transport) that turn a real socket into something a test can drive deterministically.

/// `ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]`, read once per call, never logged,
/// never compared to anything, never touched beyond handing it straight to `URLRequest`. `XCTSkip`
/// rather than a thrown error so a run without the flag or the key reports *skipped*, not failed.
func requireLiveElevenLabsApiKey() throws -> String {
    try XCTSkipUnless(
        ProcessInfo.processInfo.environment["PAI_LIVE_ELEVENLABS"] == "1",
        "set PAI_LIVE_ELEVENLABS=1 to run the live ElevenLabs tests"
    )
    guard let key = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"], !key.isEmpty else {
        throw XCTSkip("ELEVENLABS_API_KEY is not set in the environment")
    }
    return key
}

/// Linux Foundation's `URLSession` cannot open a WebSocket (it fails with "WebSockets not
/// supported by libcurl"), so the socket tests only run where Apple's `URLSession` does. The
/// batch test is plain HTTP and runs everywhere.
func requireLiveWebSockets() throws {
    #if !canImport(Darwin)
        throw XCTSkip("WebSocket live tests need Apple's URLSession; run them on macOS")
    #endif
}

/// The one place `xi-api-key` is ever attached to a request — every live test mints its own
/// tokens and synthesizes its own fixture through this, never through `PaiApiClient`, which talks
/// to pai-cloud's proxy rather than ElevenLabs directly.
enum LiveElevenLabsClient {
    enum TokenKind: String {
        case realtime = "realtime_scribe"
        case batch = "batch_scribe"
        case tts = "tts_websocket"
    }

    private static let session = URLSession(configuration: .ephemeral)

    static func mintToken(_ kind: TokenKind, apiKey: String) async throws -> VoiceToken {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/single-use-token/\(kind.rawValue)")!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        try Self.checkOk(response, data: data, what: "mint \(kind.rawValue)")
        struct Body: Decodable {
            let token: String; let expiresIn: Int?
            enum CodingKeys: String, CodingKey { case token; case expiresIn = "expires_in" }
        }
        let body = try JSONDecoder().decode(Body.self, from: data)
        return VoiceToken(token: body.token, expiresIn: body.expiresIn ?? 900)
    }

    /// The first voice on the account — every fixture in this file uses whichever voice that is;
    /// nothing here depends on which one it turns out to be.
    static func firstVoiceId(apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/voices")!)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        try Self.checkOk(response, data: data, what: "list voices")
        struct Voice: Decodable {
            let voiceId: String
            enum CodingKeys: String, CodingKey { case voiceId = "voice_id" }
        }
        struct Body: Decodable { let voices: [Voice] }
        let body = try JSONDecoder().decode(Body.self, from: data)
        guard let first = body.voices.first else { throw LiveTestError.noVoicesOnAccount }
        return first.voiceId
    }

    /// `POST /v1/text-to-speech/{voice}?output_format=pcm_16000` — raw little-endian PCM back,
    /// not JSON, matching what `VoiceRealtimeProtocol`'s realtime endpoint expects as input: this
    /// is the oracle every live test's word assertions are checked against.
    static func synthesizeSpeech(text: String, voiceId: String, apiKey: String) async throws -> [Int16] {
        var components = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)")
        components?.queryItems = [URLQueryItem(name: "output_format", value: "pcm_16000")]
        var request = URLRequest(url: components!.url!)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["text": text, "model_id": "eleven_flash_v2_5"])
        let (data, response) = try await session.data(for: request)
        try Self.checkOk(response, data: data, what: "synthesize speech")
        return VoiceTtsProtocol.pcm16Samples(fromLE: data)
    }

    private static func checkOk(_ response: URLResponse, data: Data, what: String) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(decoding: data.prefix(200), as: UTF8.self)
            throw LiveTestError.requestFailed(what: what, status: status, body: VoiceCredentialRedaction.redact(body))
        }
    }
}

enum LiveTestError: Error, CustomStringConvertible {
    case noVoicesOnAccount
    case requestFailed(what: String, status: Int, body: String)
    case timedOut(String)

    var description: String {
        switch self {
        case .noVoicesOnAccount: return "the account has no voices configured"
        case let .requestFailed(what, status, body): return "\(what) failed: HTTP \(status) \(body)"
        case let .timedOut(what): return "timed out waiting for \(what)"
        }
    }
}

/// One synthesized clip, cached for the whole test run — every method that needs the same phrase
/// gets it from here instead of paying for another TTS round trip, which is most of what keeps
/// the live class inside a few minutes rather than growing with every test that needs speech.
actor LiveSpeechFixtureCache {
    static let shared = LiveSpeechFixtureCache()

    private var voiceId: String?
    private var clips: [String: [Int16]] = [:]

    func voice(apiKey: String) async throws -> String {
        if let voiceId { return voiceId }
        let id = try await LiveElevenLabsClient.firstVoiceId(apiKey: apiKey)
        voiceId = id
        return id
    }

    func speech(_ text: String, apiKey: String) async throws -> [Int16] {
        if let cached = clips[text] { return cached }
        let voiceId = try await voice(apiKey: apiKey)
        let samples = try await LiveElevenLabsClient.synthesizeSpeech(text: text, voiceId: voiceId, apiKey: apiKey)
        clips[text] = samples
        return samples
    }
}

/// A running log a real socket's receive loop appends to — read with `waitUntilLive` below rather
/// than a continuation, matching the polling style the rest of this package's own fake-transport
/// tests already use, just against a real wall clock instead of a fake one.
actor LiveMessageLog<Message: Sendable> {
    private(set) var messages: [Message] = []
    func append(_ message: Message) { messages.append(message) }
}

/// Polls `condition` against real wall-clock time — the live equivalent of `FlakyPipelineTests`'
/// `waitUntil(async:)`, which polls a fake clock's `Task.yield()` instead. A live socket has no
/// clock to fake, so this is genuinely rate-limited (`pollMs`) rather than spun as fast as
/// possible. `@MainActor` because every condition closure in this file reads a `@MainActor`
/// `VoiceRecordingSession` or captures state formed on the test method's own `@MainActor` context
/// — keeping this on the same actor is what lets those closures be passed here at all.
@MainActor
func waitUntilLive(
    timeoutSeconds: Double, pollMs: UInt64 = 100, _ condition: () async -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
    }
    return await condition()
}

/// A single mutable counter a `@Sendable` closure can read and increment — `ElevenLabsLiveTests`'
/// `makeRealtimeTransport` closure is called once per connection attempt (the first connect and
/// every reconnect alike) and needs to know which attempt it is, the same `@unchecked Sendable`
/// shape `FlakyPipelineTests`' `PoisonFlag` already uses for the equivalent problem against a fake
/// transport.
final class LiveConnectionAttemptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Wraps the real ElevenLabs realtime transport and forces the underlying socket closed once a
/// caller-chosen number of `send` calls has gone out — the live test's way of making an actual
/// ElevenLabs connection drop on command, since nothing else here can. Every other call passes
/// straight through to `URLSessionVoiceRealtimeTransport`, so what the test drives afterward
/// (reconnect, `previous_text`, the burst) is the same real transport `VoiceRecordingSession` uses
/// in the shipped app, not a stand-in for it.
actor LiveDropRealtimeTransport: VoiceRealtimeTransport {
    private let real = URLSessionVoiceRealtimeTransport()
    private let dropAfterSendCount: Int?
    private var sendCount = 0

    init(dropAfterSendCount: Int?) {
        self.dropAfterSendCount = dropAfterSendCount
    }

    func connect(url: URL) async throws {
        try await real.connect(url: url)
    }

    func send(text: String) async throws {
        try await real.send(text: text)
        sendCount += 1
        if let dropAfterSendCount, sendCount == dropAfterSendCount {
            // Closing here rather than merely throwing from `receive()` is what makes this a real
            // drop: the in-flight `receive()` on `real` (running in `VoiceRecordingSession`'s own
            // receive loop) fails exactly the way it would for a lost connection, with no fake
            // error type standing in for ElevenLabs' own.
            await real.close(code: 1006, reason: "forced by the live pipeline test")
        }
    }

    func receive() async throws -> String {
        try await real.receive()
    }

    func close(code: Int, reason: String?) async {
        await real.close(code: code, reason: reason)
    }
}

/// Reads back a range of the exact PCM the test itself transmitted — the live test's stand-in for
/// a take's `-sent.wav` file, since there is no `VoiceRecorderController` here to write one.
/// Backed by whatever the test already accumulated in memory, not a real file: `BatchBackfiller`
/// only ever asks for byte ranges, so an in-memory `Data` answers exactly like a real seek-and-read
/// would.
struct LiveInMemoryTakeAudioReader: TakeAudioReader {
    let pcm16leData: Data

    func readSamples(id: String, range: WavByteRange) async throws -> Data {
        let start = range.offset - WavHeaderReader.headerByteCount
        guard start >= 0, start < pcm16leData.count else { return Data() }
        let end = min(start + range.length, pcm16leData.count)
        guard start < end else { return Data() }
        return pcm16leData.subdata(in: start..<end)
    }
}

func packPcm16LE(_ samples: [Int16]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
        var little = sample.littleEndian
        Swift.withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    return data
}

/// Lowercased, punctuation-stripped words — what the live tests compare against instead of exact
/// text equality, since a real STT round trip may differ from the oracle in case or an inserted
/// comma without differing in the one thing these tests actually check: which words came back, and
/// in what order.
func normalizedWords(_ text: String) -> [String] {
    text.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { !$0.isEmpty }
}

/// Asserts every word of `oracle` appears in `actual`, in order, exactly once each — the property
/// `SeamMerge` exists to guarantee (no word dropped at a seam, none duplicated across it), checked
/// against whatever a real ElevenLabs round trip actually produced rather than a scripted fake.
/// Words are matched one at a time, left to right, so a genuinely duplicated or missing word fails
/// at the word that proves it rather than only at a whole-string comparison.
func assertWordsAppearInOrderExactlyOnce(
    oracle: [String], actual: [String], file: StaticString = #filePath, line: UInt = #line
) {
    var searchFrom = 0
    for word in oracle {
        guard let foundIndex = actual[searchFrom...].firstIndex(of: word) else {
            XCTFail(
                "expected \"\(word)\" after position \(searchFrom) in \(actual) (oracle: \(oracle))",
                file: file, line: line
            )
            return
        }
        searchFrom = foundIndex + 1
    }
}
