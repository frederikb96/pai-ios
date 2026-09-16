import Foundation

/// The wire contract for ElevenLabs' multi-context text-to-speech WebSocket
/// (`wss://api.elevenlabs.io/v1/text-to-speech/{voice_id}/multi-stream-input`) — message shapes
/// and the connection URL only, no socket. `VoiceTtsTransport` owns the connection this talks
/// over, the same split `VoiceRealtimeProtocol`/`VoiceRealtimeTransport` already draws for STT.
///
/// One socket per call, one context per reply: `SpeechOutputSession` opens a fresh `context_id`
/// for each queued reply and closes it once spoken or skipped, rather than reusing one context for
/// the whole call — "computer skip" is exactly `CloseContextClient` on the reply in progress.
public enum VoiceTtsProtocol {
    /// `model_id` — ElevenLabs documents "~75ms" model latency for this tier, the right trade for
    /// a reply spoken back while Freddy is waiting on it mid-ride.
    public static let modelId = "eleven_flash_v2_5"
    /// `output_format` — raw PCM straight into `AVAudioPlayerNode`, matching `SpeechOutput`'s own
    /// sample rate; no decoder, and a sample-accurate stop for skip.
    public static let outputFormat = "pcm_24000"
    /// Left at ElevenLabs' documented default. Speaking rate is applied client-side instead, on
    /// the played audio's own `AVAudioUnitTimePitch` node — unbounded, adjustable mid-playback,
    /// and it never asks the model to synthesize at a speed it was not trained for.
    public static let voiceSettingsSpeed = 1.0
    /// The voice call mode speaks in when Freddy has never pasted one of his own — a premade
    /// ElevenLabs voice ("George"), fast and clear. An empty voice id in the connection URL fails
    /// the handshake outright (ElevenLabs closes with 1002, never sending the 101 that would open
    /// the socket), so falling through to ElevenLabs' own server-side default was never actually
    /// happening; this is the one place that fallback is named, so nothing else needs to guess at
    /// it. `resolvedVoiceId(_:)` is the only caller that should ever read this.
    public static let defaultVoiceId = "JBFqnCBsd6RMkjVDRZzb"
    /// `voiceId`, or ``defaultVoiceId`` when Freddy has not pasted one — the single place this
    /// fallback is decided, so a connection is never attempted with an empty voice id.
    public static func resolvedVoiceId(_ voiceId: String) -> String {
        voiceId.isEmpty ? defaultVoiceId : voiceId
    }
    /// `inactivity_timeout` — ElevenLabs closes the whole connection, not just one context, after
    /// this many seconds with no activity on any context; documented default is 20s, this is the
    /// documented ceiling. Requested unconditionally: a call sits quiet between replies for far
    /// longer than 20s as a matter of course (waiting on Freddy, waiting on a reply to generate),
    /// so the default would treat an ordinary pause as a dropped connection. `SpeechOutputSession`
    /// pings a dedicated context well inside this ceiling to keep a genuinely idle connection open
    /// the rest of the way.
    public static let maxInactivityTimeoutSeconds = 180

    public static func connectionURL(voiceId: String, token: String) -> URL? {
        let encodedVoiceId =
            voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? voiceId
        var components = URLComponents(
            string: "wss://api.elevenlabs.io/v1/text-to-speech/\(encodedVoiceId)/multi-stream-input")
        components?.queryItems = [
            URLQueryItem(name: "model_id", value: modelId),
            URLQueryItem(name: "output_format", value: outputFormat),
            URLQueryItem(name: "enable_logging", value: "false"),
            URLQueryItem(name: "single_use_token", value: token),
            URLQueryItem(name: "inactivity_timeout", value: String(maxInactivityTimeoutSeconds)),
        ]
        return components?.url
    }

    /// The reverse of `RealtimeUplinkChunk.audioBase64(fromPCM16LE:)` — ElevenLabs' `pcm_24000`
    /// output format decoded into signed 16-bit little-endian samples, once, in the one place
    /// both a test and `SpeechOutput`'s buffer scheduling need it from.
    public static func pcm16Samples(fromBase64 base64: String) -> [Int16]? {
        guard let data = Data(base64Encoded: base64) else { return nil }
        return pcm16Samples(fromLE: data)
    }

    static func pcm16Samples(fromLE data: Data) -> [Int16] {
        let sampleCount = data.count / 2
        guard sampleCount > 0 else { return [] }
        var samples = [Int16](repeating: 0, count: sampleCount)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let base = raw.startIndex
            for index in 0..<sampleCount {
                let low = UInt16(bytes[base + index * 2])
                let high = UInt16(bytes[base + index * 2 + 1])
                samples[index] = Int16(bitPattern: low | (high << 8))
            }
        }
        return samples
    }

    /// `pcm16Samples` normalised to `-1...1`, ready to fill an `AVAudioPCMBuffer`'s float channel
    /// data directly — the one piece of the app's own buffer construction worth proving for free
    /// rather than trusting on a device.
    public static func floatSamples(fromBase64 base64: String) -> [Float]? {
        pcm16Samples(fromBase64: base64)?.map { Float($0) / 32768.0 }
    }
}

/// One client -> server frame on the multi-context socket. Each case encodes only the fields
/// ElevenLabs documents for it, never a field that message type has no defined meaning for.
public enum TtsUplinkMessage: Sendable, Equatable {
    /// `InitialiseContext` — opens `contextId` with the socket's voice settings, primed with a
    /// single space the way ElevenLabs' own example does. One per reply.
    case initializeContext(contextId: String)
    /// `SendTextMulti`. `flush` forces generation of whatever is already buffered for this
    /// context rather than waiting for ElevenLabs' own chunking schedule to fill — set on the
    /// last sentence of a reply so the tail is not left waiting in the buffer.
    case sendText(contextId: String, text: String, flush: Bool = false)
    case flushContext(contextId: String)
    /// `CloseContextClient` — "computer skip", or the ordinary end of a reply once its audio has
    /// fully arrived.
    case closeContext(contextId: String)
    case closeSocket
    /// `KeepContextAlive` — resets a context's own inactivity timeout with an empty payload; sent
    /// on a dedicated context kept open for exactly this, across the silent stretches between
    /// replies when no reply context is open to hold the connection up on its own.
    case keepContextAlive(contextId: String)

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

extension TtsUplinkMessage: Encodable {
    private enum CodingKeys: String, CodingKey {
        case text
        case contextId = "context_id"
        case flush
        case closeContext = "close_context"
        case closeSocket = "close_socket"
        case voiceSettings = "voice_settings"
    }

    private struct VoiceSettingsPayload: Encodable {
        let speed = VoiceTtsProtocol.voiceSettingsSpeed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .initializeContext(let contextId):
            try container.encode(" ", forKey: .text)
            try container.encode(contextId, forKey: .contextId)
            try container.encode(VoiceSettingsPayload(), forKey: .voiceSettings)
        case .sendText(let contextId, let text, let flush):
            try container.encode(text, forKey: .text)
            try container.encode(contextId, forKey: .contextId)
            if flush { try container.encode(true, forKey: .flush) }
        case .flushContext(let contextId):
            try container.encode(contextId, forKey: .contextId)
            try container.encode(true, forKey: .flush)
        case .closeContext(let contextId):
            try container.encode(contextId, forKey: .contextId)
            try container.encode(true, forKey: .closeContext)
        case .closeSocket:
            try container.encode(true, forKey: .closeSocket)
        case .keepContextAlive(let contextId):
            try container.encode("", forKey: .text)
            try container.encode(contextId, forKey: .contextId)
        }
    }
}

/// Server -> client messages, decoded from the two shapes ElevenLabs documents for this endpoint.
/// `.unrecognized` rather than throwing on a body that parses as JSON but matches neither shape —
/// a field ElevenLabs adds later must not crash a live call, matching
/// `RealtimeDownlinkMessage.unrecognized`'s own reasoning for the STT side.
public enum TtsDownlinkMessage: Sendable, Equatable {
    /// `AudioOutputMulti` — one base64-encoded PCM chunk for `contextId`. `contextId` is `nil`
    /// only for a malformed server response; every documented example carries it.
    case audio(contextId: String?, base64: String)
    /// `FinalOutputMulti` — `isFinal: true`: every chunk for this context has now arrived.
    case contextFinished(contextId: String?)
    case unrecognized(raw: String)

    private struct Envelope: Decodable {
        let audio: String?
        let contextId: String?
        let isFinal: Bool?
    }

    public static func decode(_ text: String) -> TtsDownlinkMessage? {
        guard let data = text.data(using: .utf8),
            let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        else { return nil }
        if let audio = envelope.audio {
            return .audio(contextId: envelope.contextId, base64: audio)
        }
        if envelope.isFinal == true {
            return .contextFinished(contextId: envelope.contextId)
        }
        return .unrecognized(raw: text)
    }
}
