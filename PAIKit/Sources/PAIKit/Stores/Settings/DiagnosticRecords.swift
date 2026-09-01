import Foundation

/// One entry in the Settings screen's "Sent Messages" list — a recovery aid for a message that
/// did not land, not a setting. Port of `stores/settings.ts`'s `SentMessage`.
public struct SentMessage: Codable, Sendable, Equatable {
    public let text: String
    /// Milliseconds since the epoch, matching the web's `Date.now()` — kept as the same unit
    /// rather than converted, since nothing here needs `Date` arithmetic on it.
    public let timestampMs: Double

    public init(text: String, timestampMs: Double) {
        self.text = text
        self.timestampMs = timestampMs
    }
}

/// Why a recording stopped — the first thing to know when one is too short. Port of
/// `stores/settings.ts`'s `RecordingEnd`, plus `.crashed`, which the web has no equivalent of:
/// only iOS reconciles a take the app never got to close (`RecordingReconciliation`).
public enum RecordingEndReason: String, Codable, Sendable, CaseIterable {
    case user, silence, interrupted, error
    case connectionLost = "connection-lost"
    /// Never written by `VoiceRecorderController.persistRecording()` — only by
    /// `RecordingReconciliation.metadata(for:)`, for a take a startup pass found on disk with no
    /// matching `RecordingMeta`. Lets the row read as recovered rather than an ordinary take.
    case crashed
}

/// The device the recording was captured on, as far as it could be told at the time — port of
/// `web/src/utils/audio.ts`'s `MicDiagnostics`. Conceptually the voice-capture block's shape;
/// defined here only because `RecordingMeta` needs it and nothing else has claimed it yet.
public struct MicDiagnostics: Codable, Sendable, Equatable {
    public let label: String
    public let trackSampleRate: Double?
    public let contextSampleRate: Double
    public let channelCount: Int?
    public let echoCancellation: Bool?
    public let noiseSuppression: Bool?
    public let autoGainControl: Bool?
    public let userAgent: String

    public init(
        label: String, trackSampleRate: Double?, contextSampleRate: Double, channelCount: Int?,
        echoCancellation: Bool?, noiseSuppression: Bool?, autoGainControl: Bool?, userAgent: String
    ) {
        self.label = label
        self.trackSampleRate = trackSampleRate
        self.contextSampleRate = contextSampleRate
        self.channelCount = channelCount
        self.echoCancellation = echoCancellation
        self.noiseSuppression = noiseSuppression
        self.autoGainControl = autoGainControl
        self.userAgent = userAgent
    }
}

/// Loudness over one capture — port of `web/src/utils/audio.ts`'s `LevelStats`.
public struct LevelStats: Codable, Sendable, Equatable {
    public let peak: Double
    public let rms: Double
    public let clippedSamples: Int
    public let totalSamples: Int

    public init(peak: Double, rms: Double, clippedSamples: Int, totalSamples: Int) {
        self.peak = peak
        self.rms = rms
        self.clippedSamples = clippedSamples
        self.totalSamples = totalSamples
    }
}

/// Silence detection as it stood for one recording, and whether it is what ended it. Port of
/// `stores/settings.ts`'s `SilenceMeta`.
public struct SilenceMeta: Codable, Sendable, Equatable {
    public let enabled: Bool
    public let threshold: Double
    public let durationMs: Double
    public let triggered: Bool

    public init(enabled: Bool, threshold: Double, durationMs: Double, triggered: Bool) {
        self.enabled = enabled
        self.threshold = threshold
        self.durationMs = durationMs
        self.triggered = triggered
    }
}

/// The transcription request as it was actually made. Port of `stores/settings.ts`'s `SttMeta`.
public struct SttMeta: Codable, Sendable, Equatable {
    public let model: String
    public let language: String
    public let vadSilenceSecs: Double
    public let vadThreshold: Double

    public init(model: String, language: String, vadSilenceSecs: Double, vadThreshold: Double) {
        self.model = model
        self.language = language
        self.vadSilenceSecs = vadSilenceSecs
        self.vadThreshold = vadThreshold
    }
}

/// How long capture took to get going, from the moment the mic was tapped. Port of
/// `stores/settings.ts`'s `RecordingStartup`.
public struct RecordingStartup: Codable, Sendable, Equatable {
    public let captureMs: Double
    /// `nil` when the socket never opened.
    public let socketMs: Double?

    public init(captureMs: Double, socketMs: Double?) {
        self.captureMs = captureMs
        self.socketMs = socketMs
    }
}

/// One entry in the Settings screen's "Recordings" diagnostic list — everything about a
/// recording except the audio itself, which the voice-capture block stores separately (the web
/// keeps it in IndexedDB, keyed by `timestampMs`; an iOS equivalent is that block's decision,
/// not this one's). Port of `stores/settings.ts`'s `RecordingMeta`.
///
/// Every field past `durationMs` is optional because a recording made by an earlier app version
/// is still in the list and must still open — nothing here is ever re-derived once stored, so a
/// reader degrades rather than assumes a field it predates is present.
public struct RecordingMeta: Codable, Sendable, Equatable, Identifiable {
    /// The capture's own timestamp, which is also the web's IndexedDB key for the audio. Identity
    /// that does not depend on list position — that changes every time a newer recording lands.
    public var id: String { Self.id(forTimestampMs: timestampMs) }

    /// The same formula `id` uses, exposed so a caller that must name a take's files *before*
    /// this `RecordingMeta` exists — streaming audio to disk as it is captured, rather than only
    /// once the take is over — can compute the identical path without duplicating the formula.
    public static func id(forTimestampMs timestampMs: Double) -> String { String(Int(timestampMs)) }

    public let timestampMs: Double
    public let durationMs: Double
    /// Rate the audio was sent at. Absent on recordings from before this was tracked.
    public let sampleRate: Double?
    /// Rate actually captured at — the rate the raw audio is stored at.
    public let rawSampleRate: Double?
    public let mic: MicDiagnostics?
    /// `false` when the untouched capture could not be kept (quota, or too long).
    public let rawStored: Bool?
    public let endedBy: RecordingEndReason?
    public let silence: SilenceMeta?
    public let stt: SttMeta?
    /// What the live transcription produced — what a re-run is compared against.
    public let transcript: String?
    /// Measured on the capture, before any conversion.
    public let levels: LevelStats?
    public let narrowband: Bool?
    public let startup: RecordingStartup?
    /// Time the mic was muted. Absent when it never was.
    public let mutedMs: Double?

    public init(
        timestampMs: Double, durationMs: Double, sampleRate: Double? = nil,
        rawSampleRate: Double? = nil, mic: MicDiagnostics? = nil, rawStored: Bool? = nil,
        endedBy: RecordingEndReason? = nil, silence: SilenceMeta? = nil, stt: SttMeta? = nil,
        transcript: String? = nil, levels: LevelStats? = nil, narrowband: Bool? = nil,
        startup: RecordingStartup? = nil, mutedMs: Double? = nil
    ) {
        self.timestampMs = timestampMs
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.rawSampleRate = rawSampleRate
        self.mic = mic
        self.rawStored = rawStored
        self.endedBy = endedBy
        self.silence = silence
        self.stt = stt
        self.transcript = transcript
        self.levels = levels
        self.narrowband = narrowband
        self.startup = startup
        self.mutedMs = mutedMs
    }
}
