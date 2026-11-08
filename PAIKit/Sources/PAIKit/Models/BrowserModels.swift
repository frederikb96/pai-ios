import Foundation

/// Swift port of `pai-cloud/web/src/apps/browser/browserModel.ts`. `pai-cloud` owns this
/// contract (`docs/architecture/browser.md`); this file mirrors it rather than redefining it.

public struct BrowserHandoff: Codable, Sendable, Equatable {
    public let reason: String
    public let since: String

    public init(reason: String, since: String) {
        self.reason = reason
        self.since = since
    }
}

public struct BrowserRecordingState: Codable, Sendable, Equatable {
    /// `audio` or `video`.
    public let kind: String
    public let since: String

    public init(kind: String, since: String) {
        self.kind = kind
        self.since = since
    }
}

/// One entry of `GET /api/browser/sessions`, also the payload of a stream `state` event.
public struct BrowserSession: Codable, Sendable, Equatable, Identifiable {
    public let name: String
    /// The owning conversation's uuid (a session's `claudeSessionId`); `nil` for a session nobody owns.
    public let owner: String?
    public let kept: Bool
    public let via: String?
    public let sites: [String]?
    public let url: String
    public let title: String
    public let handoff: BrowserHandoff?
    public let recording: BrowserRecordingState?
    public let createdAt: String
    public let lastUsedAt: String

    public var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, owner, kept, via, sites, url, title, handoff, recording
        case createdAt = "created_at"
        case lastUsedAt = "last_used_at"
    }

    public init(
        name: String, owner: String? = nil, kept: Bool = false, via: String? = nil, sites: [String]? = nil,
        url: String = "", title: String = "", handoff: BrowserHandoff? = nil,
        recording: BrowserRecordingState? = nil, createdAt: String = "", lastUsedAt: String = ""
    ) {
        self.name = name
        self.owner = owner
        self.kept = kept
        self.via = via
        self.sites = sites
        self.url = url
        self.title = title
        self.handoff = handoff
        self.recording = recording
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Only `name` is required: a state event from an agent that predates a field must still draw.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        owner = try container.decodeIfPresent(String.self, forKey: .owner)
        kept = try container.decodeIfPresent(Bool.self, forKey: .kept) ?? false
        via = try container.decodeIfPresent(String.self, forKey: .via)
        sites = try container.decodeIfPresent([String].self, forKey: .sites)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        handoff = try container.decodeIfPresent(BrowserHandoff.self, forKey: .handoff)
        recording = try container.decodeIfPresent(BrowserRecordingState.self, forKey: .recording)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt) ?? ""
    }

    /// The text a row or a header shows: the page title, else the session name.
    public var displayTitle: String { title.isEmpty ? name : title }
}

public struct BrowserSessionsResponse: Codable, Sendable, Equatable {
    public let sessions: [BrowserSession]
}

/// One decoded `frame` event: the page viewport in CSS pixels and the JPEG of it.
public struct BrowserFrame: Sendable, Equatable {
    public let w: Double
    public let h: Double
    public let jpeg: Data

    public init(w: Double, h: Double, jpeg: Data) {
        self.w = w
        self.h = h
        self.jpeg = jpeg
    }
}

/// The answer to `POST .../handback`.
public struct BrowserHandbackAnswer: Codable, Sendable, Equatable {
    public let ok: Bool
    /// Whether the owning conversation was told; `false` carries a `reason`.
    public let messaged: Bool
    public let reason: String?

    public init(ok: Bool, messaged: Bool, reason: String? = nil) {
        self.ok = ok
        self.messaged = messaged
        self.reason = reason
    }
}

/// How the owner ends a handover.
public enum BrowserHandbackResult: String, Sendable, Equatable {
    case done
    case failed
}

/// What a session's SSE stream delivers, decoded. `ping` and unknown names are not events.
public enum BrowserStreamEvent: Sendable, Equatable {
    case frame(BrowserFrame)
    case state(BrowserSession)
    case end(reason: String)

    private struct FrameWire: Decodable {
        let w: Double
        let h: Double
        let jpeg: String
    }

    private struct EndWire: Decodable {
        let reason: String?
    }

    /// `nil` for a ping, an unknown event name, or a payload that does not decode: a viewer that
    /// cannot read one event keeps the last good picture rather than failing the stream.
    public static func parse(name: String, data: String) -> BrowserStreamEvent? {
        guard let bytes = data.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        switch name {
        case "frame":
            guard let wire = try? decoder.decode(FrameWire.self, from: bytes),
                let jpeg = Data(base64Encoded: wire.jpeg), wire.w > 0, wire.h > 0
            else { return nil }
            return .frame(BrowserFrame(w: wire.w, h: wire.h, jpeg: jpeg))
        case "state":
            return (try? decoder.decode(BrowserSession.self, from: bytes)).map { .state($0) }
        case "end":
            let reason = (try? decoder.decode(EndWire.self, from: bytes))?.reason
            return .end(reason: reason ?? "The session ended")
        default:
            return nil
        }
    }
}
