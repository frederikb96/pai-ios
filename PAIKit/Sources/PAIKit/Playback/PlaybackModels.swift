import Foundation

/// The voice that made a segment's file.
public enum PlaybackProvider: String, Codable, Sendable, Equatable {
    case elevenlabs
    case openai
}

/// One cut of a reply, synthesised on demand. `durationMs` is exact once `ready`, else `nil` and
/// `estMs` is the estimate.
public struct PlaybackSegment: Codable, Sendable, Equatable {
    public let index: Int
    public let chars: Int
    public let estMs: Int
    public let durationMs: Int?
    public let ready: Bool
    /// Which voice made the stored file; `nil` until someone has asked for it.
    public let provider: PlaybackProvider?
    /// True when the backup voice made it.
    public let fallback: Bool

    enum CodingKeys: String, CodingKey {
        case index, chars, ready, provider, fallback
        case estMs = "est_ms"
        case durationMs = "duration_ms"
    }

    public init(
        index: Int, chars: Int, estMs: Int, durationMs: Int? = nil, ready: Bool = false,
        provider: PlaybackProvider? = nil, fallback: Bool = false
    ) {
        self.index = index
        self.chars = chars
        self.estMs = estMs
        self.durationMs = durationMs
        self.ready = ready
        self.provider = provider
        self.fallback = fallback
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        chars = try container.decode(Int.self, forKey: .chars)
        estMs = try container.decode(Int.self, forKey: .estMs)
        durationMs = try container.decodeIfPresent(Int.self, forKey: .durationMs)
        ready = try container.decode(Bool.self, forKey: .ready)
        // A voice this client does not know reads as none rather than failing the manifest.
        provider = (try? container.decodeIfPresent(String.self, forKey: .provider)).flatMap(PlaybackProvider.init)
        fallback = try container.decodeIfPresent(Bool.self, forKey: .fallback) ?? false
    }
}

/// The backup voice's month for this person, in euro cents. `available` is false when it is off or
/// has no key.
public struct PlaybackBackupUsage: Codable, Sendable, Equatable {
    public let available: Bool
    public let budgetCents: Int
    public let spentCents: Int

    enum CodingKeys: String, CodingKey {
        case available
        case budgetCents = "budget_cents"
        case spentCents = "spent_cents"
    }
}

/// This person's ElevenLabs credits today against their daily ceiling (`nil` until the month has
/// been read once), and their backup voice month. Keys beyond these are ignored.
public struct PlaybackUsage: Codable, Sendable, Equatable {
    public let creditsUsed: Int
    public let dailyCreditCap: Int?
    public let resetsAt: String
    public let backup: PlaybackBackupUsage?

    enum CodingKeys: String, CodingKey {
        case backup
        case creditsUsed = "credits_used"
        case dailyCreditCap = "daily_credit_cap"
        case resetsAt = "resets_at"
    }
}

/// `GET /api/session/{id}/playback/{message_id}`: free, synthesises nothing.
public struct PlaybackManifest: Codable, Sendable, Equatable {
    public let messageId: Int
    public let voiceId: String?
    public let model: String
    public let segments: [PlaybackSegment]
    public let usage: PlaybackUsage

    enum CodingKeys: String, CodingKey {
        case model, segments, usage
        case messageId = "message_id"
        case voiceId = "voice_id"
    }
}

/// A playback route refused. Its `detail` is an object (`code`, `message`) rather than the string
/// every other route answers, so `PaiError` would have shown it as a decoding failure; `message`
/// is the sentence to show the person as it is.
public struct PlaybackRefusal: Error, Sendable, Equatable {
    public let status: Int
    /// `playback_cap_reached`, `playback_saving_credits`, ... Absent on a plain 404 or a proxy answer.
    public let code: String?
    public let message: String

    public init(status: Int, code: String?, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// 404 means the reply has nothing to read aloud.
    public var isNothingToRead: Bool { status == 404 }

    /// Refusals about one part alone (its voice failed on that text): the player skips the part and
    /// plays on. Every other refusal is a limit that would refuse the next part too, so it stops.
    public static let partFailureCodes: Set<String> = ["playback_backup_failed", "playback_synthesis_failed"]

    public var isPartFailure: Bool { code.map(Self.partFailureCodes.contains) ?? false }

    /// What a part that failed earlier answers with when it is asked for again.
    static let unreadablePart = PlaybackRefusal(
        status: 502, code: "playback_synthesis_failed", message: "This part could not be read aloud.")

    /// Reads a refusal from an error response's body.
    public static func parse(status: Int, body: Data) -> PlaybackRefusal {
        struct Body: Decodable {
            struct Detail: Decodable {
                let code: String?
                let message: String?
            }
            enum Shape {
                case object(Detail)
                case text(String)
            }
            let shape: Shape?

            enum CodingKeys: String, CodingKey { case detail }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let detail = try? container.decode(Detail.self, forKey: .detail) {
                    shape = .object(detail)
                } else if let text = try? container.decode(String.self, forKey: .detail) {
                    shape = .text(text)
                } else {
                    shape = nil
                }
            }
        }
        switch (try? JSONDecoder().decode(Body.self, from: body))?.shape {
        case let .object(detail)?:
            return PlaybackRefusal(
                status: status, code: detail.code, message: detail.message ?? "HTTP \(status)")
        case let .text(text)?:
            return PlaybackRefusal(status: status, code: nil, message: text)
        case nil:
            return PlaybackRefusal(status: status, code: nil, message: "HTTP \(status)")
        }
    }
}

/// One segment's audio and the voice that made it (the `X-Playback-Provider` header, the exact
/// moment a switch to the backup voice happens).
public struct PlaybackSegmentAudio: Sendable, Equatable {
    public let data: Data
    public let provider: PlaybackProvider?

    public init(data: Data, provider: PlaybackProvider?) {
        self.data = data
        self.provider = provider
    }
}

/// One voice of the ElevenLabs account, as `GET /api/playback/voices` lists it.
public struct PlaybackVoiceChoice: Codable, Sendable, Equatable, Identifiable {
    public let voiceId: String
    public let name: String
    /// ISO 639-1, when the voice says.
    public let language: String?
    public let gender: String?

    public var id: String { voiceId }

    /// What the picker shows: the name, with the language when there is one.
    public var label: String { language.map { "\(name) (\($0))" } ?? name }

    enum CodingKeys: String, CodingKey {
        case name, language, gender
        case voiceId = "voice_id"
    }

    public init(voiceId: String, name: String, language: String? = nil, gender: String? = nil) {
        self.voiceId = voiceId
        self.name = name
        self.language = language
        self.gender = gender
    }
}

/// `GET /api/playback/voices`: what a person can pick from.
public struct PlaybackVoices: Codable, Sendable, Equatable {
    /// The account's voices; empty while ElevenLabs cannot be read.
    public let elevenlabs: [PlaybackVoiceChoice]
    /// The voice of everyone who has not picked their own.
    public let defaultVoiceId: String
    public let builtinVoiceId: String
    public let backup: [String]
    public let backupVoice: String

    enum CodingKeys: String, CodingKey {
        case elevenlabs, backup
        case defaultVoiceId = "default_voice_id"
        case builtinVoiceId = "builtin_voice_id"
        case backupVoice = "backup_voice"
    }

    public init(
        elevenlabs: [PlaybackVoiceChoice], defaultVoiceId: String, builtinVoiceId: String, backup: [String],
        backupVoice: String
    ) {
        self.elevenlabs = elevenlabs
        self.defaultVoiceId = defaultVoiceId
        self.builtinVoiceId = builtinVoiceId
        self.backup = backup
        self.backupVoice = backupVoice
    }

    /// What the default voice is called: its name from the list, else its id.
    public var defaultVoiceLabel: String {
        elevenlabs.first { $0.voiceId == defaultVoiceId }?.label ?? defaultVoiceId
    }
}
