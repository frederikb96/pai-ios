import Foundation

/// The wire shapes of PAI Cloud's `GET /api/voice/socket` — Swift port of
/// `pai-cloud/docs/VOICE_PROTOCOL.md`. This module owns parsing/building frames only; nothing here
/// opens a connection or decides what to do with one (`VoiceSocketTransport`/`VoiceUplinkSession`).
///
/// Binary framing: an uplink audio frame is `[u32 seq][u32 sample_offset][pcm16 le]`; a downlink
/// audio frame is `[u32 ref][pcm16 le]`. Both integers are big-endian, per the protocol doc.
public enum VoiceSocketProtocol {
    public static let audioUplinkHz = 16_000
    public static let audioDownlinkHz = 24_000

    /// `hello.transport` for this app.
    public static let transportName = "ios"
}

/// Which transport a `hello` frame is speaking for, and what it can and cannot receive — the
/// protocol doc's own `caps` object. iOS always declares an audio downlink (it can play
/// synthesized speech back), so it is never the transport a `transcript` down frame targets —
/// transcribed words reach it only through the draft it is dictating into.
public struct VoiceSocketCapabilities: Sendable, Equatable {
    public var audioDownlink: Bool
    public var dtmf: Bool

    public init(audioDownlink: Bool = true, dtmf: Bool = false) {
        self.audioDownlink = audioDownlink
        self.dtmf = dtmf
    }

    var jsonObject: [String: Any] {
        ["audio_downlink": audioDownlink, "dtmf": dtmf]
    }
}

/// A control a screen offers as a button, naming the same thing one of a call's spoken commands
/// names — `docs/VOICE_PROTOCOL.md`'s `command` up frame. Only a bus a Kai session's call mode
/// owns acts on these.
///
/// The raw values are the backend's own vocabulary (`call_engine.CLIENT_COMMANDS`), which is its
/// spoken grammar plus `start`: there is no spoken "start", because what begins a take by voice
/// is the wake word rather than a phrase.
///
/// Deliberately not `CommandKind`, which this package also carries: that type is the Swift
/// original's *recogniser* vocabulary and still names three kinds this backend has no concept of
/// (`start` there means something else again — a locally-detected phrase). A wire enum that could
/// express a value no engine acts on would be a frame nothing answers.
public enum VoiceCallCommand: String, Sendable, Equatable, CaseIterable {
    /// Begin a take — the button equivalent of saying the wake word.
    case start
    /// End the take without sending it; the call drops back to its quiet phase.
    case stop
    /// End the take and send what was dictated to the session.
    case send
    /// Drop the reply currently being spoken.
    case skip
    /// Leave the session and return to Computer, without ending the call. Only the backend can
    /// do this — switching which engine a bus is attached to is its own act, not the client's.
    case listen
}

// The spoken grammar's "end" has no case here on purpose: hanging up is something this client
// does itself, by closing the socket (`ComputerCallController.end()`), which works on either
// face and while the connection is too unhealthy for a frame to arrive. Asking the backend to
// hang up would be a second mechanism for one action, and the one that fails exactly when it is
// most wanted.

// MARK: - Up frames: client -> backend

public enum VoiceUpFrame: Sendable, Equatable {
    /// `connectSession` asks the backend to attach this socket straight to that Kai session's
    /// call mode, skipping Computer and the spoken "connect me to…" round trip — what the
    /// launcher's own call tiles and a composer's "Call this session" send. Only ever read on a
    /// FRESH bus: a reconnect keeps whatever engine it already had, so sending it again on every
    /// hello costs nothing and keeps it a property of the session rather than of one connect.
    case hello(
        transport: String, caps: VoiceSocketCapabilities, auth: String, resumeToken: String?,
        draftKey: String?, connectSession: String? = nil
    )
    /// `takeId` is the client-minted identity of the take this `open: true` starts — present only
    /// for a take dictating into a draft (`docs/VOICE_PROTOCOL.md` "Addressing a take"), carried
    /// through unchanged so a later backfill, or a `PUT /api/drafts/{key}/takes/{take_id}`
    /// recovering a long outage, addresses the exact same draft region rather than opening a new
    /// one. `nil` on `open: false` and on any gate this take's own identity does not apply to.
    case gate(open: Bool, reason: String, takeId: String? = nil)
    case played(ref: Int)
    case dtmf(digit: String)
    case command(VoiceCallCommand)
    case bye(reason: String)
    case pong

    /// The JSON text frame `WebSocket.send` should carry — never called for a binary audio frame,
    /// which `VoiceSocketProtocol.packUplinkAudio` builds instead.
    func encoded() throws -> String {
        var object: [String: Any] = ["type": type]
        switch self {
        case let .hello(transport, caps, auth, resumeToken, draftKey, connectSession):
            object["transport"] = transport
            object["caps"] = caps.jsonObject
            object["auth"] = auth
            if let resumeToken { object["resume_token"] = resumeToken }
            if let draftKey { object["draft_key"] = draftKey }
            if let connectSession { object["connect_session"] = connectSession }
        case let .gate(open, reason, takeId):
            object["open"] = open
            object["reason"] = reason
            if let takeId { object["take_id"] = takeId }
        case let .played(ref):
            object["ref"] = ref
        case let .dtmf(digit):
            object["digit"] = digit
        case let .command(command):
            object["kind"] = command.rawValue
        case let .bye(reason):
            object["reason"] = reason
        case .pong:
            break
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private var type: String {
        switch self {
        case .hello: return "hello"
        case .gate: return "gate"
        case .played: return "played"
        case .dtmf: return "dtmf"
        case .command: return "command"
        case .bye: return "bye"
        case .pong: return "pong"
        }
    }
}

// MARK: - Down frames: backend -> client

public enum VoiceBusOwner: String, Sendable, Equatable {
    case computer, call, transcription
    case unrecognized
}

public enum VoiceDownFrame: Sendable, Equatable {
    /// `resumed` is `true` when this answers a `hello` that reattached to a bus already in
    /// progress (a reconnect within the grace window, or a takeover), `false` for a genuinely
    /// fresh bus — independent of the socket's own `seq`, which restarts at 0 on every `hello`
    /// regardless of `resumed` (protocol doc, "Framing": "`seq` always restarts at 0 on the
    /// reconnected socket, even when `ready.resumed` is `true`").
    case ready(resumeToken: String, busOwner: VoiceBusOwner, resumed: Bool, sessionId: String?)
    case clear
    case ack(throughSeq: Int)
    case state(busOwner: VoiceBusOwner, phase: String, sessionId: String?, checkpoint: String?)
    case notice(severity: String, code: String, text: String)
    case ping
    case transcript(text: String, isFinal: Bool, seq: Int)
    /// A `type` this build does not recognize — logged and otherwise ignored, matching the
    /// protocol doc: "a client that does not recognise a code falls back to showing `text`
    /// plainly", generalized here to the whole frame so a backend release ahead of this app never
    /// breaks a live socket.
    case unrecognized(type: String)

    static func decode(_ raw: [String: Any]) -> VoiceDownFrame? {
        guard let type = raw["type"] as? String else { return nil }
        switch type {
        case "ready":
            guard let resumeToken = raw["resume_token"] as? String else { return nil }
            let owner = VoiceBusOwner(rawValue: raw["bus_owner"] as? String ?? "") ?? .unrecognized
            // Missing (a backend older than this field) reads as `false` — the safe fallback,
            // since a client that wrongly believes a fresh bus is resumed skips reopening state
            // the backend never actually kept.
            let resumed = raw["resumed"] as? Bool ?? false
            return .ready(
                resumeToken: resumeToken, busOwner: owner, resumed: resumed, sessionId: raw["session_id"] as? String)
        case "clear":
            return .clear
        case "ack":
            guard let throughSeq = raw["through_seq"] as? Int else { return nil }
            return .ack(throughSeq: throughSeq)
        case "state":
            let owner = VoiceBusOwner(rawValue: raw["bus_owner"] as? String ?? "") ?? .unrecognized
            guard let phase = raw["phase"] as? String else { return nil }
            return .state(
                busOwner: owner, phase: phase, sessionId: raw["session_id"] as? String,
                checkpoint: raw["checkpoint"] as? String
            )
        case "notice":
            guard let severity = raw["severity"] as? String, let code = raw["code"] as? String,
                let text = raw["text"] as? String
            else { return nil }
            return .notice(severity: severity, code: code, text: text)
        case "ping":
            return .ping
        case "transcript":
            guard let text = raw["text"] as? String, let isFinal = raw["is_final"] as? Bool,
                let seq = raw["seq"] as? Int
            else { return nil }
            return .transcript(text: text, isFinal: isFinal, seq: seq)
        default:
            return .unrecognized(type: type)
        }
    }

    /// `nil` on a body that is not even valid JSON, or not a JSON object — the caller drops it.
    public static func decode(_ jsonText: String) -> VoiceDownFrame? {
        guard let data = jsonText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decode(object)
    }
}

/// `notice.code` values this backend currently emits — see `docs/VOICE_PROTOCOL.md`. A client
/// falls back to showing `text` plainly for anything else.
public enum VoiceNoticeCode {
    public static let sttReconnecting = "stt_reconnecting"
    public static let sttDegraded = "stt_degraded"
    public static let ttsFailed = "tts_failed"
    public static let sessionUnreachable = "session_unreachable"
    public static let sessionBlocked = "session_blocked"
    public static let draftUnavailable = "draft_unavailable"
    public static let authExpired = "auth_expired"
    public static let backendDraining = "backend_draining"
    public static let takenOver = "taken_over"
}

// MARK: - Binary framing

extension VoiceSocketProtocol {
    /// Builds one uplink audio frame: `[u32 seq][u32 sample_offset][pcm16 le]`, big-endian header.
    public static func packUplinkAudio(seq: Int, sampleOffset: Int, pcm16le samples: [Int16]) -> Data {
        var data = Data(capacity: 8 + samples.count * 2)
        data.append(bigEndianU32: UInt32(truncatingIfNeeded: seq))
        data.append(bigEndianU32: UInt32(truncatingIfNeeded: sampleOffset))
        samples.withUnsafeBufferPointer { buffer in
            buffer.forEach { sample in
                let le = sample.littleEndian
                data.append(UInt8(truncatingIfNeeded: le))
                data.append(UInt8(truncatingIfNeeded: le >> 8))
            }
        }
        return data
    }

    /// Splits a downlink audio frame into its `ref` and PCM payload — `nil` if it is shorter than
    /// the header alone.
    public static func unpackDownlinkAudio(_ data: Data) -> (ref: Int, pcm: Data)? {
        guard data.count >= 4 else { return nil }
        let ref = Int(data.readBigEndianU32(at: 0))
        return (ref, data.suffix(from: data.startIndex + 4))
    }
}

extension Data {
    fileprivate mutating func append(bigEndianU32 value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    fileprivate func readBigEndianU32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) << 24 | UInt32(self[base + 1]) << 16 | UInt32(self[base + 2]) << 8
            | UInt32(self[base + 3])
    }
}
