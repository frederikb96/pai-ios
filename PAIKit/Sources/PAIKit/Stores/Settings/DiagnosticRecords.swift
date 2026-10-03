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
    case user, interrupted, error
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

/// Where a recording's stored `transcript` came from: the take's own live transcription, or a
/// batch pass over the whole recording (a re-transcribe, or the automatic one a standalone
/// recording gets once it stops).
public enum RecordingTranscriptSource: String, Codable, Sendable, Equatable {
    case live, batch
}

/// One entry in the past-recordings list — everything about a recording except the audio
/// itself, which `FileRecordingAudioStorage` keeps beside it on disk. Port of
/// `stores/settings.ts`'s `RecordingMeta`.
///
/// Every field past `durationMs` is optional because a recording made by an earlier app version
/// is still in the list and must still open — nothing here is ever re-derived once stored, so a
/// reader degrades rather than assumes a field it predates is present. Decoding is lenient for
/// the same reason: the list is stored as one array, and a single entry carrying an `endedBy`
/// value this build no longer writes would otherwise fail every entry with it.
public struct RecordingMeta: Codable, Sendable, Equatable, Identifiable {
    /// The capture's own timestamp, which is also the name of the audio on disk. Identity that
    /// does not depend on list position — that changes every time a newer recording lands.
    public var id: String { Self.id(forTimestampMs: timestampMs) }

    /// The same formula `id` uses, exposed so a caller that must name a take's files *before*
    /// this `RecordingMeta` exists — streaming audio to disk as it is captured, rather than only
    /// once the take is over — can compute the identical path without duplicating the formula.
    public static func id(forTimestampMs timestampMs: Double) -> String { String(Int(timestampMs)) }

    public let timestampMs: Double
    public let durationMs: Double
    /// Rate of the stored audio. Absent on recordings from before this was tracked; the WAV
    /// header on disk is the authority either way.
    public let sampleRate: Double?
    public let mic: MicDiagnostics?
    public let endedBy: RecordingEndReason?
    /// The take's own text — no `stt-rec: ` prefix and none of the draft text that preceded it.
    public let transcript: String?
    public let transcriptSource: RecordingTranscriptSource?
    /// `false` when the take ended without the backend confirming its tail (the finishing wait
    /// ran out, the link was down, or the backend reported the tail unavailable) — the row then
    /// offers a re-transcribe rather than presenting a possibly-truncated text as whole.
    public let transcriptComplete: Bool?
    /// Measured on the capture, before any conversion.
    public let levels: LevelStats?
    public let narrowband: Bool?
    /// Time the mic was muted. Absent when it never was.
    public let mutedMs: Double?
    /// The durable pipeline's own view of this take's coverage — absent for a recording made
    /// before the ledger existed, and for one still in progress.
    public let transcription: TranscriptionMeta?
    /// Set at start for a standalone recording. A label for recognition — sorting stays
    /// chronological by `timestampMs` regardless of whether this is set.
    public let name: String?
    /// `nil` means `.microphone` — an ordinary dictation take, the only kind that existed before
    /// this field did, so an old recording decodes as exactly what it always was. `.offline` is
    /// the standalone recording: no session, no uplink. Nothing here ever produces `.call`, which
    /// lives entirely server-side.
    public let mode: VoiceMode?

    public init(
        timestampMs: Double, durationMs: Double, sampleRate: Double? = nil, mic: MicDiagnostics? = nil,
        endedBy: RecordingEndReason? = nil, transcript: String? = nil,
        transcriptSource: RecordingTranscriptSource? = nil, transcriptComplete: Bool? = nil,
        levels: LevelStats? = nil, narrowband: Bool? = nil, mutedMs: Double? = nil,
        transcription: TranscriptionMeta? = nil, name: String? = nil, mode: VoiceMode? = nil
    ) {
        self.timestampMs = timestampMs
        self.durationMs = durationMs
        self.sampleRate = sampleRate
        self.mic = mic
        self.endedBy = endedBy
        self.transcript = transcript
        self.transcriptSource = transcriptSource
        self.transcriptComplete = transcriptComplete
        self.levels = levels
        self.narrowband = narrowband
        self.mutedMs = mutedMs
        self.transcription = transcription
        self.name = name
        self.mode = mode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timestampMs = try container.decode(Double.self, forKey: .timestampMs)
        durationMs = try container.decode(Double.self, forKey: .durationMs)
        sampleRate = try? container.decodeIfPresent(Double.self, forKey: .sampleRate)
        mic = try? container.decodeIfPresent(MicDiagnostics.self, forKey: .mic)
        endedBy = try? container.decodeIfPresent(RecordingEndReason.self, forKey: .endedBy)
        transcript = try? container.decodeIfPresent(String.self, forKey: .transcript)
        transcriptSource = try? container.decodeIfPresent(RecordingTranscriptSource.self, forKey: .transcriptSource)
        transcriptComplete = try? container.decodeIfPresent(Bool.self, forKey: .transcriptComplete)
        levels = try? container.decodeIfPresent(LevelStats.self, forKey: .levels)
        narrowband = try? container.decodeIfPresent(Bool.self, forKey: .narrowband)
        mutedMs = try? container.decodeIfPresent(Double.self, forKey: .mutedMs)
        transcription = try? container.decodeIfPresent(TranscriptionMeta.self, forKey: .transcription)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
        mode = try? container.decodeIfPresent(VoiceMode.self, forKey: .mode)
    }

    /// A copy with the transcript fields replaced — what a re-transcribe, a backfill heal and
    /// the standalone auto-transcribe all write, so none of them rebuilds the other fields by
    /// hand and silently drops one.
    public func withTranscript(
        _ transcript: String?, source: RecordingTranscriptSource?, complete: Bool?,
        transcription: TranscriptionMeta? = nil
    ) -> RecordingMeta {
        RecordingMeta(
            timestampMs: timestampMs, durationMs: durationMs, sampleRate: sampleRate, mic: mic, endedBy: endedBy,
            transcript: transcript, transcriptSource: source, transcriptComplete: complete, levels: levels,
            narrowband: narrowband, mutedMs: mutedMs, transcription: transcription ?? self.transcription, name: name,
            mode: mode
        )
    }
}
