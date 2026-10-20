import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts`'s "Voice takes" section. A dictation is a
/// server-side resource: the audio is stored before it is acknowledged, a durable job turns it
/// into text, and a send can wait on that text. The behaviour (states, transitions, idempotency)
/// is `docs/VOICE_PROTOCOL.md` "Takes" and "Held sends"; these are its shapes.
///
/// `SampleRange` (`Range<Int>`) already encodes as the wire's two-element `[start, end]` array —
/// the standard library's `Range` `Codable` conformance is an unkeyed container of the two
/// bounds, and it refuses a reversed pair rather than trapping.

/// A string enum on the wire that keeps a value this build does not know rather than failing
/// the whole response over it — the same rule `SessionStatus` documents, written once for the
/// voice take enums.
public protocol WireStringEnum: Codable, Sendable, Hashable {
    static var knownValues: [String: Self] { get }
    static func unrecognized(_ raw: String) -> Self
    var wireValue: String { get }
}

extension WireStringEnum {
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// What the transcription engine does with a take's audio: `live` streams it to realtime
/// transcription as it arrives, `batch` transcribes the whole take after the seal.
public enum VoiceSttMode: WireStringEnum {
    case live, batch
    case unrecognized(String)

    public static var knownValues: [String: VoiceSttMode] { ["live": .live, "batch": .batch] }

    public var wireValue: String {
        switch self {
        case .live: "live"
        case .batch: "batch"
        case let .unrecognized(raw): raw
        }
    }
}

public enum VoiceTakeState: WireStringEnum {
    case open, sealed, resolving, done, failed
    case unrecognized(String)

    public static var knownValues: [String: VoiceTakeState] {
        ["open": .open, "sealed": .sealed, "resolving": .resolving, "done": .done, "failed": .failed]
    }

    public var wireValue: String {
        switch self {
        case .open: "open"
        case .sealed: "sealed"
        case .resolving: "resolving"
        case .done: "done"
        case .failed: "failed"
        case let .unrecognized(raw): raw
        }
    }
}

/// `take_done.ended` and `VoiceTake.ended` share one vocabulary.
public enum VoiceTakeEnded: WireStringEnum {
    case committed, recovered, empty, abandoned, unavailable
    case unrecognized(String)

    public static var knownValues: [String: VoiceTakeEnded] {
        [
            "committed": .committed, "recovered": .recovered, "empty": .empty, "abandoned": .abandoned,
            "unavailable": .unavailable,
        ]
    }

    public var wireValue: String {
        switch self {
        case .committed: "committed"
        case .recovered: "recovered"
        case .empty: "empty"
        case .abandoned: "abandoned"
        case .unavailable: "unavailable"
        case let .unrecognized(raw): raw
        }
    }
}

public enum VoiceTakeFailureCode: WireStringEnum {
    case transcriptionFailed, transcriptionNotConfigured, internalError
    case unrecognized(String)

    public static var knownValues: [String: VoiceTakeFailureCode] {
        [
            "transcription_failed": .transcriptionFailed,
            "transcription_not_configured": .transcriptionNotConfigured, "internal": .internalError,
        ]
    }

    public var wireValue: String {
        switch self {
        case .transcriptionFailed: "transcription_failed"
        case .transcriptionNotConfigured: "transcription_not_configured"
        case .internalError: "internal"
        case let .unrecognized(raw): raw
        }
    }
}

public struct VoiceTakeFailure: Codable, Sendable, Equatable {
    public let code: VoiceTakeFailureCode
    public let detail: String

    public init(code: VoiceTakeFailureCode, detail: String) {
        self.code = code
        self.detail = detail
    }
}

/// `held`: waiting on the take; `released`: sent; `withdrawn`: pulled back by Undo send.
public enum HeldMessageState: WireStringEnum {
    case held, released, withdrawn
    case unrecognized(String)

    public static var knownValues: [String: HeldMessageState] {
        ["held": .held, "released": .released, "withdrawn": .withdrawn]
    }

    public var wireValue: String {
        switch self {
        case .held: "held"
        case .released: "released"
        case .withdrawn: "withdrawn"
        case let .unrecognized(raw): raw
        }
    }
}

/// The send waiting on a take. Never cleared once set: it is what tells a client that comes back
/// later not to heal a draft with words the session already has.
public struct VoiceTakeHeldMessage: Codable, Sendable, Equatable {
    public let clientMessageId: String
    public let sessionId: String
    public let state: HeldMessageState

    enum CodingKeys: String, CodingKey {
        case clientMessageId = "client_message_id"
        case sessionId = "session_id"
        case state
    }

    public init(clientMessageId: String, sessionId: String, state: HeldMessageState) {
        self.clientMessageId = clientMessageId
        self.sessionId = sessionId
        self.state = state
    }
}

/// `GET /api/voice/takes/{take_id}`; also the answer of seal and retry, and `take` in an upload's
/// answer.
public struct VoiceTake: Codable, Sendable, Equatable {
    public let takeId: String
    public let mode: VoiceSttMode
    public let state: VoiceTakeState
    /// `nil` for a standalone take.
    public let draftKey: String?
    public let standaloneName: String?
    /// The capturing client's device name.
    public let device: String?
    /// The length the seal fixed; `nil` while `open`.
    public let capturedSamples: Int?
    /// Audio the server holds, sorted and merged.
    public let received: [SampleRange]
    public let withheld: [SampleRange]
    /// `[0, captured_samples) − received − withheld`: what a device still has to upload.
    public let missing: [SampleRange]
    /// The whole transcript, bare words, authoritative for the take; `nil` until `done`.
    public let text: String?
    public let ended: VoiceTakeEnded?
    public let heldMessage: VoiceTakeHeldMessage?
    public let failure: VoiceTakeFailure?
    public let createdAt: String
    public let sealedAt: String?
    public let doneAt: String?

    enum CodingKeys: String, CodingKey {
        case takeId = "take_id"
        case mode, state
        case draftKey = "draft_key"
        case standaloneName = "standalone_name"
        case device
        case capturedSamples = "captured_samples"
        case received, withheld, missing, text, ended
        case heldMessage = "held_message"
        case failure
        case createdAt = "created_at"
        case sealedAt = "sealed_at"
        case doneAt = "done_at"
    }

    public init(
        takeId: String, mode: VoiceSttMode, state: VoiceTakeState, draftKey: String? = nil,
        standaloneName: String? = nil, device: String? = nil, capturedSamples: Int? = nil,
        received: [SampleRange] = [], withheld: [SampleRange] = [], missing: [SampleRange] = [], text: String? = nil,
        ended: VoiceTakeEnded? = nil, heldMessage: VoiceTakeHeldMessage? = nil, failure: VoiceTakeFailure? = nil,
        createdAt: String, sealedAt: String? = nil, doneAt: String? = nil
    ) {
        self.takeId = takeId
        self.mode = mode
        self.state = state
        self.draftKey = draftKey
        self.standaloneName = standaloneName
        self.device = device
        self.capturedSamples = capturedSamples
        self.received = received
        self.withheld = withheld
        self.missing = missing
        self.text = text
        self.ended = ended
        self.heldMessage = heldMessage
        self.failure = failure
        self.createdAt = createdAt
        self.sealedAt = sealedAt
        self.doneAt = doneAt
    }
}

/// `POST /api/voice/takes/{take_id}/seal`. Creates the take when it is unknown; an absent
/// `draft_key` then means standalone.
public struct VoiceTakeSeal: Codable, Sendable, Equatable {
    public let mode: VoiceSttMode
    public let capturedSamples: Int
    public let withheld: [SampleRange]?
    public let draftKey: String?
    public let standaloneName: String?
    public let device: String?

    enum CodingKeys: String, CodingKey {
        case mode
        case capturedSamples = "captured_samples"
        case withheld
        case draftKey = "draft_key"
        case standaloneName = "standalone_name"
        case device
    }

    public init(
        mode: VoiceSttMode, capturedSamples: Int, withheld: [SampleRange]? = nil, draftKey: String? = nil,
        standaloneName: String? = nil, device: String? = nil
    ) {
        self.mode = mode
        self.capturedSamples = capturedSamples
        self.withheld = withheld
        self.draftKey = draftKey
        self.standaloneName = standaloneName
        self.device = device
    }
}

/// `POST /api/voice/takes/{take_id}/audio` with `into_take=true`.
public struct VoiceTakeUploadResponse: Codable, Sendable, Equatable {
    public let take: VoiceTake

    public init(take: VoiceTake) {
        self.take = take
    }
}

/// The JSON of the `held_take` multipart field on the send routes. `before`/`after` are strings,
/// never offsets: Swift, JavaScript and Python count characters differently.
public struct HeldTake: Codable, Sendable, Equatable {
    public let takeId: String
    public let mode: VoiceSttMode
    /// The draft text preceding the take's words when Send was pressed.
    public let before: String
    /// The text typed after them.
    public let after: String
    public let capturedSamples: Int
    public let withheld: [SampleRange]?

    enum CodingKeys: String, CodingKey {
        case takeId = "take_id"
        case mode, before, after
        case capturedSamples = "captured_samples"
        case withheld
    }

    public init(
        takeId: String, mode: VoiceSttMode, before: String, after: String, capturedSamples: Int,
        withheld: [SampleRange]? = nil
    ) {
        self.takeId = takeId
        self.mode = mode
        self.before = before
        self.after = after
        self.capturedSamples = capturedSamples
        self.withheld = withheld
    }
}
