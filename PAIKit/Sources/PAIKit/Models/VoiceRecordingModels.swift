import Foundation

// MARK: - Debug recordings
//
// What the backend itself handed to each engine — ElevenLabs realtime, OpenAI Realtime, the
// wake-word classifier — stored byte for byte, one recording per stint. Mirrors
// `web/src/api/types.ts`' `DebugRecording`.

/// A detail value on a debug-recording event — the wire carries strings or numbers.
public enum DebugRecordingDetailValue: Codable, Sendable, Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            self = .number(number)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .string(let value): value
        case .number(let value): String(format: "%g", value)
        }
    }
}

public struct DebugRecordingEvent: Codable, Sendable, Equatable {
    public let sample: Int
    public let kind: String
    public let detail: [String: DebugRecordingDetailValue]?
}

public struct DebugRecording: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// `dictation` | `call_dictation` | `wake` | `computer` — kept as the wire string, so a kind a
    /// newer backend adds still lists rather than failing the whole response.
    public let kind: String
    /// `elevenlabs_realtime` | `elevenlabs_batch` (an uploaded take) | `openai_realtime` | `wake_word`.
    public let engine: String
    public let model: String
    public let transport: String
    public let device: String?
    public let mics: [String]
    public let busId: String
    public let sessionId: String?
    public let sessionTitle: String?
    public let takeId: String?
    public let sampleRate: Int
    public let encoding: String
    public let channels: Int
    public let startedAt: String
    public let endedAt: String?
    public let durationMs: Int
    public let byteCount: Int
    public let peakDbfs: Double?
    public let rmsDbfs: Double?
    public let clippedSamples: Int
    /// `recording` | `complete` | `interrupted` | `failed`.
    public let status: String
    public let endReason: String?
    public let truncated: Bool
    public let events: [DebugRecordingEvent]

    enum CodingKeys: String, CodingKey {
        case id, kind, engine, model, transport, device, mics, encoding, channels, status, truncated, events
        case busId = "bus_id"
        case sessionId = "session_id"
        case sessionTitle = "session_title"
        case takeId = "take_id"
        case sampleRate = "sample_rate"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationMs = "duration_ms"
        case byteCount = "byte_count"
        case peakDbfs = "peak_dbfs"
        case rmsDbfs = "rms_dbfs"
        case clippedSamples = "clipped_samples"
        case endReason = "end_reason"
    }

    public var isStillRecording: Bool { status == "recording" }
}

public struct DebugRecordingList: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let recordings: [DebugRecording]
}

// MARK: - Wake-word corpus
//
// Takes recorded on the phone's sample screen, kept on the backend until deleted — the material a
// wake-word retrain or threshold tune starts from. Mirrors `web/src/api/types.ts`' `WakeWordRun`.

public enum WakeWordSampleKind: String, Codable, Sendable, Equatable, CaseIterable {
    /// Says the wake word.
    case positive
    /// Some other word or speech the classifier must learn is not the wake word.
    case negative
}

public struct WakeWordTake: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let index: Int
    public let recordedAt: String
    public let durationMs: Int

    enum CodingKeys: String, CodingKey {
        case id, index
        case recordedAt = "recorded_at"
        case durationMs = "duration_ms"
    }

    public init(id: String, index: Int, recordedAt: String, durationMs: Int) {
        self.id = id
        self.index = index
        self.recordedAt = recordedAt
        self.durationMs = durationMs
    }
}

public struct WakeWordRun: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    /// Kept as the wire string so a run of a kind this build does not know still lists.
    public let kind: String
    public let label: String
    public let device: String?
    public let mic: String?
    public let source: String
    public let sampleRate: Int
    public let createdAt: String
    public let takes: [WakeWordTake]

    enum CodingKeys: String, CodingKey {
        case id, kind, label, device, mic, source, takes
        case sampleRate = "sample_rate"
        case createdAt = "created_at"
    }
}

public struct WakeWordRunList: Codable, Sendable, Equatable {
    public let runs: [WakeWordRun]
}

/// The body of `PUT /api/wake-word/runs/{run_id}` — the run's own description, sent before its
/// first take so the backend knows what the takes belong to.
public struct WakeWordRunUpload: Codable, Sendable, Equatable {
    public let kind: WakeWordSampleKind
    public let label: String
    public let device: String?
    public let mic: String?
    public let source: String
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case kind, label, device, mic, source
        case createdAt = "created_at"
    }

    public init(kind: WakeWordSampleKind, label: String, device: String?, mic: String?, createdAt: String) {
        self.kind = kind
        self.label = label
        self.device = device
        self.mic = mic
        self.source = "recorded"
        self.createdAt = createdAt
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(label, forKey: .label)
        try container.encode(device, forKey: .device)
        try container.encode(mic, forKey: .mic)
        try container.encode(source, forKey: .source)
        try container.encode(createdAt, forKey: .createdAt)
    }
}
