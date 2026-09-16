import Foundation

/// One occurrence `FeedbackPolicy` turns into a cue, a notification, both or neither. Carries
/// just enough to word the notification; dedup and rate limiting are `FeedbackPolicy`'s own job,
/// not this type's.
public enum FeedbackEvent: Sendable, Equatable {
    case connectionDropped(reason: String?)
    case serverNotice(String)
    case mintFailed
    case reconnected
    case gapOpened
    case backfillCompleted
    case backfillFailed
    case fatalProtocolError(String)
    case captureRestarted
    case captureGaveUp
    case interruptionPaused
    case interruptionResumed
    case ttsDropped
    case ttsReconnected
    /// ElevenLabs rejected the request itself — an unknown voice id, a bad or missing key —
    /// before ever sending audio. Never a drop: retrying cannot fix a rejection like this, only
    /// changing the setting it names can. `reason` is the machine-readable code
    /// (`voice_id_does_not_exist`, `authentication_required`, …) `FeedbackPolicy` dedupes by;
    /// `message` is ElevenLabs' own human-readable text, logged verbatim.
    case ttsRejected(reason: String, message: String)
    case replyNotSpoken
    case commandRecognized(CommandKind)
    /// A command configured to run offline has no `.onnx` classifier in the app bundle — that
    /// command is silently unreachable by voice until this is fixed, never a crash.
    case commandModelMissing(CommandKind)
}

/// The earcon `EarconPlayer` plays for a `FeedbackEvent` — `Earcon.samples(kind:rate:)` is what
/// actually synthesizes one.
public enum EarconKind: Sendable, Equatable {
    case drop, reconnect, healed, error, pause
    /// One tone per command, distinct per command — exempt from `FeedbackPolicy`'s rate
    /// limiting, since a swallowed confirmation is worse than a chatty one.
    case command(CommandKind)
}
