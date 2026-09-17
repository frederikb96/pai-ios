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
    /// A call's recording cycle could not open its transcription connection. The audio is still
    /// saved and transcribed later, but nothing is live until the next start.
    case recordingStartFailed(reason: String)
    /// A call's turn was not sent — refused or failed. Its text is back in the draft.
    case sendFailed
    case commandRecognized(CommandKind)
    /// The "computer" wake-word classifier has no `.onnx` file in the app bundle — a call is
    /// silently unreachable by voice until this is fixed, never a crash. Always carries `.start`,
    /// the only command the offline engine ever means.
    case commandModelMissing(CommandKind)
    /// A call ended for a reason other than a deliberate End tap — a spoken "computer end", or a
    /// teardown neither channel asked for. Worth its own cue and notification: the whole point of
    /// call mode is running hands-free with the phone out of sight, so an ending Freddy did not
    /// just watch happen on screen needs telling about, especially when `hadUnsentText` — the
    /// draft now holds words he never got to review before they stopped being collected.
    case callEndedUnexpectedly(hadUnsentText: Bool)
}

/// The earcon `EarconPlayer` plays for a `FeedbackEvent` — `Earcon.samples(kind:rate:)` is what
/// actually synthesizes one.
public enum EarconKind: Sendable, Equatable {
    case drop, reconnect, healed, error, pause
    /// One tone per command, distinct per command — exempt from `FeedbackPolicy`'s rate
    /// limiting, since a swallowed confirmation is worse than a chatty one.
    case command(CommandKind)
}
