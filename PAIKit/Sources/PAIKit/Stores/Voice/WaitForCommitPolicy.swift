import Foundation

/// Governs `VoiceRecordingSession.stop()`'s wait for ElevenLabs' final segment after the commit
/// frame is sent. Android polls a `hasPendingTranscriptions` flag up to a 5s cap rather than the
/// web's flat 500ms sleep, and the report recommends porting Android's form: a slow final segment
/// is not truncated, and a fast one does not cost the full wait either way.
public enum WaitForCommitPolicy {
    public static let timeoutMs = 5000
    public static let pollIntervalMs = 100

    /// Pure so the timeout boundary is testable without waiting out a real 5 seconds — the only
    /// state it needs is already in the caller's hands.
    public static func shouldContinueWaiting(elapsedMs: Int, commitReceived: Bool) -> Bool {
        !commitReceived && elapsedMs < timeoutMs
    }
}

/// What a finished take produced. `sampleRate`/`narrowband` are `0`/`false` when the session
/// never actually started (its result read before the first `start()`), consistent with `text`
/// starting empty rather than throwing on the missing case — the app is expected to read this
/// only after `stop()` completes.
public struct VoiceRecordingResult: Sendable, Equatable {
    public static let sttPrefix = "stt-rec: "

    public let text: String
    public let endedBy: RecordingEndReason
    public let durationMs: Int
    public let mutedMs: Int
    public let sampleRate: Int
    public let narrowband: Bool

    public init(
        text: String, endedBy: RecordingEndReason, durationMs: Int, mutedMs: Int, sampleRate: Int, narrowband: Bool
    ) {
        self.text = text
        self.endedBy = endedBy
        self.durationMs = durationMs
        self.mutedMs = mutedMs
        self.sampleRate = sampleRate
        self.narrowband = narrowband
    }

    /// The composer-ready string. `""` stays `""` rather than becoming a bare prefix — an empty
    /// take (an immediate silence-stop, say) inserting `"stt-rec: "` alone would read as a blank
    /// speech bubble with no indication anything went wrong, and the marker exists to explain
    /// content, not to announce its absence.
    public var prefixedText: String {
        text.isEmpty ? "" : "\(Self.sttPrefix)\(text)"
    }
}
