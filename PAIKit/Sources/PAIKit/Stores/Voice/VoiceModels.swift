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

/// Client-local voice preferences — the web keeps these in `localStorage`, iOS in
/// `UserDefaults`; this is the value type either side reads and writes, with the web's own
/// defaults (`stores/settings.ts`).
public struct VoiceSettings: Sendable, Equatable {
    public enum Language: String, Sendable, Equatable, Codable {
        case auto, en, de
    }

    public var sttLanguage: Language
    /// `''` means the system default input — never a real device identifier, so it is always
    /// safe to persist even when no device is currently selected.
    public var micDeviceId: String
    public var silenceDetectionEnabled: Bool
    public var silenceThreshold: Double
    public var silenceDurationMs: Int

    public init(
        sttLanguage: Language = .auto,
        micDeviceId: String = "",
        silenceDetectionEnabled: Bool = false,
        silenceThreshold: Double = 0.005,
        silenceDurationMs: Int = 3000
    ) {
        self.sttLanguage = sttLanguage
        self.micDeviceId = micDeviceId
        self.silenceDetectionEnabled = silenceDetectionEnabled
        self.silenceThreshold = silenceThreshold
        self.silenceDurationMs = silenceDurationMs
    }
}
