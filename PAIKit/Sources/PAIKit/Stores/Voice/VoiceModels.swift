import Foundation

/// The recording's lifecycle. `.connecting` covers everything between the user's tap and the
/// realtime socket actually accepting audio — token mint, transport connect, waiting for
/// `session_started` — so the UI has one spinner state for all of it rather than several.
///
/// `.paused` and `.reconnecting` both keep the take alive rather than ending it, and both exist
/// because a live recording must survive things a short dictation never had to: `.paused` is an
/// `AVAudioSession` interruption (a call, Siri, another app taking the mic) — capture has
/// stopped, but the socket and everything transcribed so far are kept, waiting for
/// `resumeAfterInterruption()`. `.reconnecting` is the same idea for a dropped network
/// connection — the mic keeps capturing (buffered, same as before `session_started` on the very
/// first connect), while a fresh connection is negotiated in the background.
///
/// `.transcriptionStopped` is distinct from all of these: a fatal protocol error (a rejected
/// token, an exhausted quota) means no further reconnect attempt can ever succeed, but the take
/// itself has not ended — capture keeps writing to disk, and whatever never reached ElevenLabs
/// live is exactly what the batch backfill exists to fill in later. Only `stop()` — the user, or
/// whatever ends the take on their behalf — ever leaves this state.
public enum VoiceRecordingState: Sendable, Equatable {
    case idle
    case connecting
    case recording
    case paused
    case reconnecting
    case stopping
    case transcriptionStopped
}

/// The marker every dictated text carries, so a session reading it knows it came from speech and
/// may hold transcription errors.
public enum VoiceRecordingResult {
    public static let sttPrefix = "stt-rec: "
}
