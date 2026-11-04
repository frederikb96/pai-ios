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

/// What today's synthesis allows this person. `allowanceLimited` false means no shared allowance
/// applies today; true means a day's allowance is shared. Both credit figures are `nil` while the
/// provider's pool cannot be read.
public struct PlaybackUsage: Codable, Sendable, Equatable {
    public let creditsUsed: Int
    public let dailyCreditCap: Int
    public let allowanceLimited: Bool
    public let allowanceCredits: Int?
    public let availableCredits: Int?
    public let resetsAt: String
    public let backup: PlaybackBackupUsage?

    enum CodingKeys: String, CodingKey {
        case backup
        case creditsUsed = "credits_used"
        case dailyCreditCap = "daily_credit_cap"
        case allowanceLimited = "allowance_limited"
        case allowanceCredits = "allowance_credits"
        case availableCredits = "available_credits"
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
    /// `playback_cap_reached`, `playback_paused_for_dictation`, ... Absent on a plain 404 or a proxy answer.
    public let code: String?
    public let message: String

    public init(status: Int, code: String?, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// 404 means the reply has nothing to read aloud.
    public var isNothingToRead: Bool { status == 404 }

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
