import Foundation

/// The wire contract for ElevenLabs' realtime speech-to-text WebSocket
/// (`wss://api.elevenlabs.io/v1/speech-to-text/realtime`) — message shapes and constants only, no
/// socket. `VoiceRealtimeTransport` owns the connection this talks over.
public enum VoiceRealtimeProtocol {
    /// `model_id` — the realtime model. Distinct from `VoiceBatchTranscriber.modelId`
    /// (`scribe_v2`), which the batch endpoint uses instead.
    public static let modelId = "scribe_v2_realtime"
    public static let vadSilenceThresholdSecs = "1.5"
    public static let vadThreshold = "0.4"
    /// `CHUNK_INTERVAL_MS` — how often the app should hand a captured buffer to
    /// `VoiceRecordingSession.ingestAudioChunk`. Advisory only: nothing here enforces the
    /// cadence, the same way nothing here captures audio.
    public static let chunkIntervalMs = 100
    /// Samples in the commit frame's silent payload — 240 samples of digital silence, matching
    /// the web's `new Int16Array(240)` sent alongside `commit: true` to flush ElevenLabs' final
    /// segment before the socket closes.
    public static let commitFrameSampleCount = 240

    /// Builds the connection URL. `languageCode` is omitted entirely when the setting is
    /// `.auto` — sending an empty string is a different request than sending none, and
    /// ElevenLabs' auto-detect behaviour is "parameter absent", not "parameter empty".
    public static func connectionURL(
        token: String, sampleRate: Int, language: VoiceSettings.Language
    ) -> URL? {
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")
        var query = [
            URLQueryItem(name: "model_id", value: modelId),
            URLQueryItem(name: "audio_format", value: "pcm_\(sampleRate)"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: vadSilenceThresholdSecs),
            URLQueryItem(name: "vad_threshold", value: vadThreshold),
            URLQueryItem(name: "enable_logging", value: "false"),
            URLQueryItem(name: "token", value: token),
        ]
        if language != .auto {
            query.append(URLQueryItem(name: "language_code", value: language.rawValue))
        }
        components?.queryItems = query
        return components?.url
    }
}

/// One `input_audio_chunk` frame — a client -> server text frame sent roughly every
/// `VoiceRealtimeProtocol.chunkIntervalMs`.
public struct RealtimeUplinkChunk: Encodable, Sendable, Equatable {
    public let messageType = "input_audio_chunk"
    public let audioBase64: String
    public let commit: Bool
    public let sampleRate: Int

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case audioBase64 = "audio_base_64"
        case commit
        case sampleRate = "sample_rate"
    }

    public init(audioBase64: String, commit: Bool, sampleRate: Int) {
        self.audioBase64 = audioBase64
        self.commit = commit
        self.sampleRate = sampleRate
    }

    /// The final frame of a take: `VoiceRealtimeProtocol.commitFrameSampleCount` samples of
    /// digital silence with `commit: true` — exactly what the web sends to flush ElevenLabs'
    /// last segment before closing, rather than an empty payload the protocol might reject.
    public static func commitFrame(sampleRate: Int) -> RealtimeUplinkChunk {
        let silentSamples = [Int16](repeating: 0, count: VoiceRealtimeProtocol.commitFrameSampleCount)
        return RealtimeUplinkChunk(
            audioBase64: audioBase64(fromPCM16LE: silentSamples), commit: true, sampleRate: sampleRate
        )
    }

    /// Packs LE 16-bit PCM samples — the format ElevenLabs requires — into the base64 payload a
    /// chunk frame carries. The app hands over samples already at the transport rate; this does
    /// no resampling, only byte packing.
    public static func audioBase64(fromPCM16LE samples: [Int16]) -> String {
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let littleEndian = sample.littleEndian
            bytes.append(UInt8(truncatingIfNeeded: littleEndian))
            bytes.append(UInt8(truncatingIfNeeded: littleEndian >> 8))
        }
        return Data(bytes).base64EncodedString()
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// Server -> client messages. `.unrecognized` rather than throwing on an unknown `message_type`
/// — ElevenLabs adding a message type someday must not crash a live recording; the state machine
/// already ignores anything it does not act on.
public enum RealtimeDownlinkMessage: Sendable, Equatable {
    case sessionStarted
    case partialTranscript(text: String)
    case committedTranscript(text: String)
    case error(message: String)
    case commitThrottled
    case insufficientAudioActivity
    case unrecognized(messageType: String)

    private struct Envelope: Decodable {
        let messageType: String
        let text: String?
        let message: String?
        enum CodingKeys: String, CodingKey {
            case messageType = "message_type"
            case text, message
        }
    }

    /// `nil` on a body that is not even valid JSON — the caller drops it, matching the web's
    /// `JSON.parse` inside a `try`.
    public static func decode(_ text: String) -> RealtimeDownlinkMessage? {
        guard let data = text.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }

        switch envelope.messageType {
        case "session_started": return .sessionStarted
        case "partial_transcript": return .partialTranscript(text: envelope.text ?? "")
        case "committed_transcript", "committed_transcript_with_timestamps":
            return .committedTranscript(text: envelope.text ?? "")
        case "error": return .error(message: envelope.message ?? "Unknown error")
        case "commit_throttled": return .commitThrottled
        case "insufficient_audio_activity": return .insufficientAudioActivity
        default: return .unrecognized(messageType: envelope.messageType)
        }
    }
}

/// Buffers chunks captured before the socket is ready to accept them, flushed in order once it
/// is. Non-negotiable per the web's own measurements: 1.7s for the built-in mic, 3.7s for a
/// Bluetooth headset — without this, whoever taps and talks immediately loses their first
/// sentence.
public struct PreconnectAudioBuffer<Chunk: Sendable>: Sendable {
    /// `MAX_PENDING_CHUNKS` — roughly 30s at the web's 100ms chunk cadence.
    public static var capacity: Int { 300 }

    private var chunks: [Chunk] = []

    public init() {}

    public var count: Int { chunks.count }

    /// Drops the newest chunk once full rather than the oldest: losing a moment near the 30s
    /// mark is a smaller loss than losing the very start of the take a second time, which is the
    /// exact problem this buffer exists to prevent.
    public mutating func enqueue(_ chunk: Chunk) {
        guard chunks.count < Self.capacity else { return }
        chunks.append(chunk)
    }

    /// Empties the buffer, returning chunks in the order they were enqueued.
    public mutating func drain() -> [Chunk] {
        defer { chunks = [] }
        return chunks
    }
}
