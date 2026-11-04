import Foundation

/// One person's own settings (`GET/PUT /api/settings/me`), the same on every device they sign in
/// from. Mirrors `UserSettings` in the web's `types.ts`.
public struct UserSettings: Codable, Sendable, Equatable {
    /// What a plain press on the microphone starts; the long press and the plus menu start the other.
    public var recordingMode: VoiceSttMode
    /// An ElevenLabs voice id replies are read aloud in; `nil` is the server's default voice.
    public var playbackVoiceId: String?
    public var playbackSpeed: Double
    /// Whether an agent's notification to this person may also go out by e-mail.
    public var emailNotifications: Bool

    public init(
        recordingMode: VoiceSttMode = .live, playbackVoiceId: String? = nil, playbackSpeed: Double = 1,
        emailNotifications: Bool = true
    ) {
        self.recordingMode = recordingMode
        self.playbackVoiceId = playbackVoiceId
        self.playbackSpeed = playbackSpeed
        self.emailNotifications = emailNotifications
    }

    enum CodingKeys: String, CodingKey {
        case recordingMode = "recording_mode"
        case playbackVoiceId = "playback_voice_id"
        case playbackSpeed = "playback_speed"
        case emailNotifications = "email_notifications"
    }
}

/// The slots `PUT /api/settings/me` takes, any subset. Only the voice can be cleared, which is
/// spelled out as `null`; a slot left `nil` here is not sent at all.
public struct UserSettingsPatch: Encodable, Sendable, Equatable {
    public enum Voice: Sendable, Equatable {
        case unchanged
        case set(String)
        case clear
    }

    public var recordingMode: VoiceSttMode?
    public var playbackVoice: Voice = .unchanged
    public var playbackSpeed: Double?
    public var emailNotifications: Bool?

    public init(
        recordingMode: VoiceSttMode? = nil, playbackVoice: Voice = .unchanged, playbackSpeed: Double? = nil,
        emailNotifications: Bool? = nil
    ) {
        self.recordingMode = recordingMode
        self.playbackVoice = playbackVoice
        self.playbackSpeed = playbackSpeed
        self.emailNotifications = emailNotifications
    }

    enum CodingKeys: String, CodingKey {
        case recordingMode = "recording_mode"
        case playbackVoiceId = "playback_voice_id"
        case playbackSpeed = "playback_speed"
        case emailNotifications = "email_notifications"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(recordingMode, forKey: .recordingMode)
        switch playbackVoice {
        case .unchanged: break
        case let .set(id): try container.encode(id, forKey: .playbackVoiceId)
        case .clear: try container.encodeNil(forKey: .playbackVoiceId)
        }
        try container.encodeIfPresent(playbackSpeed, forKey: .playbackSpeed)
        try container.encodeIfPresent(emailNotifications, forKey: .emailNotifications)
    }

    /// The settings as they stand once the patch is applied, for showing a change before the
    /// server has answered.
    public func applied(to settings: UserSettings) -> UserSettings {
        var next = settings
        if let recordingMode { next.recordingMode = recordingMode }
        switch playbackVoice {
        case .unchanged: break
        case let .set(id): next.playbackVoiceId = id
        case .clear: next.playbackVoiceId = nil
        }
        if let playbackSpeed { next.playbackSpeed = playbackSpeed }
        if let emailNotifications { next.emailNotifications = emailNotifications }
        return next
    }
}
