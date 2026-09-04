import Foundation

/// Swift port of the ARC v3 wire shapes — `pai_cloud.wire.ArcSpecWire`/`ArcRowWire` and
/// `pai_cloud.arc_service.recover`'s payload. `web/src/api/types.ts` owns this contract
/// (`ArcRow`, `ArcSpec`, `ArcRecoverBlock`, `ArcRecoverResponse`, `ArcLeaderG`, `ArcSseEvent`);
/// this file is a port of it, not an independent source.
///
/// A "spec" is one ARC run: rows grouped into blocks with an assigned agent, sequence markers
/// gating order. See `ArcRecoverPayload`'s doc comment for how a client reconstructs the whole
/// timeline from one call.

/// Row kind — `R` an ordinary row, `L` a block leader, `M` a sequence marker. See
/// `ArcRowStatus`'s doc comment for why this is a closed enum with an escape hatch rather than a
/// `String` raw value or a plain `enum: String`.
public enum ArcRowKind: Sendable, Hashable {
    case regular, leader, marker
    case unrecognized(String)
}

extension ArcRowKind: Codable {
    private static let knownValues: [String: ArcRowKind] = [
        "R": .regular, "L": .leader, "M": .marker,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .regular: try container.encode("R")
        case .leader: try container.encode("L")
        case .marker: try container.encode("M")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// Row status — `null` on a marker (it carries no status at all), otherwise one of five letters.
/// `.unrecognized` rather than throwing, matching `SessionStatus`'s doc comment: a status this
/// build predates must not blank the whole spec, only mislabel the one row carrying it.
public enum ArcRowStatus: Sendable, Hashable {
    case pending, inProgress, verify, done, cancelled
    case unrecognized(String)
}

extension ArcRowStatus: Codable {
    private static let knownValues: [String: ArcRowStatus] = [
        "P": .pending, "I": .inProgress, "V": .verify, "D": .done, "X": .cancelled,
    ]

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self.knownValues[raw] ?? .unrecognized(raw)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("P")
        case .inProgress: try container.encode("I")
        case .verify: try container.encode("V")
        case .done: try container.encode("D")
        case .cancelled: try container.encode("X")
        case let .unrecognized(raw): try container.encode(raw)
        }
    }
}

/// A leader row's `g` — which agent it names, and what came back. `{"type": "kai"}` alone is a
/// leader Kai does the work under himself, so every field past `type` is optional. `type` itself
/// is optional too: the server only requires `g` to be an object, never that it carries a
/// `type` key, and a hand-written row (how a leader is made outside `arc block add`, which
/// always writes one) can omit it — a present-but-invalid nested object would otherwise throw
/// out of `decodeIfPresent` and fail the whole spec's decode, not just this one row. `agentId`
/// (the subagent transcript stem) and `returnedAt` are written by the agent path once the agent
/// has actually run.
public struct ArcLeaderAgent: Codable, Sendable, Equatable {
    public let type: String?
    public let model: String?
    public let name: String?
    public let agentId: String?
    public let returnedAt: String?

    enum CodingKeys: String, CodingKey {
        case type, model, name
        case agentId = "agent_id"
        case returnedAt = "returned_at"
    }

    public init(
        type: String?, model: String? = nil, name: String? = nil, agentId: String? = nil, returnedAt: String? = nil
    ) {
        self.type = type
        self.model = model
        self.name = name
        self.agentId = agentId
        self.returnedAt = returnedAt
    }
}

/// One spec row. `id` is always present; every other field is optional here even where the
/// contract calls it required, because a caller CAN narrow the wire with a `columns` filter —
/// this app never does, but decoding defensively costs nothing and matches how every other
/// model in this file treats a field the server might omit.
public struct ArcRow: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let i: String?
    public let src: String?
    public let diff: Int?
    /// `nil` on a marker row (`k == .marker`) — markers carry no status at all, not merely an
    /// unset one.
    public let s: ArcRowStatus?
    public let o: Double?
    public let k: ArcRowKind?
    /// Block id. `nil` on a marker (forbidden there) and on a loose `P`/`D`/`X` row that
    /// belongs to no block.
    public let b: Int?
    /// Set only on a leader row (`k == .leader`).
    public let g: ArcLeaderAgent?
    public let n: [String: String]?
    public let r: [String]?
    /// On a marker, the acceptance check; on any other row, free-form notes context.
    public let v: String?

    public init(
        id: Int, i: String?, src: String?, diff: Int?, s: ArcRowStatus?, o: Double?, k: ArcRowKind?,
        b: Int?, g: ArcLeaderAgent?, n: [String: String]?, r: [String]?, v: String?
    ) {
        self.id = id
        self.i = i
        self.src = src
        self.diff = diff
        self.s = s
        self.o = o
        self.k = k
        self.b = b
        self.g = g
        self.n = n
        self.r = r
        self.v = v
    }
}

/// One ARC run — `pai_cloud.wire.ArcSpecWire`. `rowCount` is only present when the caller asked
/// for it (`GET /api/arc/specs` and `GET /api/arc/specs/{uuid}/recover` never carry it; a plain
/// `GET /api/arc/specs/{uuid}` does).
public struct ArcSpec: Codable, Sendable, Equatable, Identifiable {
    public var id: String { uuid }
    public let uuid: String
    public let name: String
    public let phase: String
    public let effort: Int
    public let projectId: String?
    /// Conversation uuids (the `CLAUDE_CODE_SESSION_ID` value) this spec is bound to — what a
    /// session's own `claudeSessionId` is checked against to find "the spec I am running under".
    public let sessions: [String]
    public let overview: String?
    public let createdAt: String
    public let updatedAt: String
    public let rowCount: Int?

    enum CodingKeys: String, CodingKey {
        case uuid, name, phase, effort
        case projectId = "project_id"
        case sessions, overview
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case rowCount = "row_count"
    }

    public init(
        uuid: String, name: String, phase: String, effort: Int, projectId: String?, sessions: [String],
        overview: String?, createdAt: String, updatedAt: String, rowCount: Int? = nil
    ) {
        self.uuid = uuid
        self.name = name
        self.phase = phase
        self.effort = effort
        self.projectId = projectId
        self.sessions = sessions
        self.overview = overview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.rowCount = rowCount
    }
}

/// One block in the run's current segment — `pai_cloud.arc_service.recover`'s own per-block
/// summary. `done`/`cancelled`/`total` count only the block's non-leader rows, matching R4
/// ("done" is never about the leader row itself).
public struct ArcRecoverBlock: Codable, Sendable, Equatable, Identifiable {
    public var id: Int { b }
    public let b: Int
    public let leader: Int?
    public let i: String?
    public let s: ArcRowStatus?
    public let g: ArcLeaderAgent?
    public let rows: [Int]
    public let done: Int
    public let cancelled: Int
    public let total: Int

    public init(
        b: Int, leader: Int?, i: String?, s: ArcRowStatus?, g: ArcLeaderAgent?, rows: [Int], done: Int,
        cancelled: Int, total: Int
    ) {
        self.b = b
        self.leader = leader
        self.i = i
        self.s = s
        self.g = g
        self.rows = rows
        self.done = done
        self.cancelled = cancelled
        self.total = total
    }
}

/// The run's current segment — the earliest one still holding unsettled work, or the last one
/// once nothing is left. `busyAgents` names every agent working right now in ANY conversation
/// the spec is bound to, spec-wide rather than scoped to this segment alone — a block outside
/// the active segment is expected to be resolved already, so membership only ever matters for
/// the segment shown here.
public struct ArcActiveSegment: Codable, Sendable, Equatable {
    public let index: Int
    public let blocks: [ArcRecoverBlock]
    public let busyAgents: [String]

    enum CodingKeys: String, CodingKey {
        case index, blocks
        case busyAgents = "busy_agents"
    }

    public init(index: Int, blocks: [ArcRecoverBlock], busyAgents: [String]) {
        self.index = index
        self.blocks = blocks
        self.busyAgents = busyAgents
    }
}

/// `GET /api/arc/specs/{uuid}/recover` — everything a client needs to draw the WHOLE spec
/// timeline in one call. `rows` carries every row in the spec, not only the active segment's —
/// `ArcSpecStore` derives segments, blocks and loose rows from it client-side, the same
/// `k`/`b`/`o` walk the backend's own `arc_rules.segments` does. `activeSegment` narrows to
/// where the run has actually got to, and is what supplies `busyAgents` for the badge state.
public struct ArcRecoverPayload: Codable, Sendable, Equatable {
    public let spec: String
    public let name: String
    public let overview: String?
    public let phase: String
    public let activeSegment: ArcActiveSegment
    /// Keyed by the row's `id` as a string — the wire's own shape, a dict rather than an array
    /// so a client can look a row up by id without building an index first.
    public let rows: [String: ArcRow]

    enum CodingKeys: String, CodingKey {
        case spec, name, overview, phase
        case activeSegment = "active_segment"
        case rows
    }

    public init(
        spec: String, name: String, overview: String?, phase: String, activeSegment: ArcActiveSegment,
        rows: [String: ArcRow]
    ) {
        self.spec = spec
        self.name = name
        self.overview = overview
        self.phase = phase
        self.activeSegment = activeSegment
        self.rows = rows
    }
}

extension ArcRow {
    /// `n`'s values joined into one markdown string, in ascending numeric key order. Every spec
    /// this app has read numbers notes "1", "2", … but the field is free-form server-side, so a
    /// non-numeric key sorts after every numeric one rather than being silently dropped. `nil`
    /// when there is nothing to show, never an empty string, so a caller can `if let` straight
    /// into "does this row have notes at all".
    public var notesMarkdown: String? {
        guard let n, !n.isEmpty else { return nil }
        let ordered = n.sorted { lhs, rhs in
            switch (Int(lhs.key), Int(rhs.key)) {
            case let (l?, r?): return l < r
            case (nil, .some): return false
            case (.some, nil): return true
            case (nil, nil): return lhs.key < rhs.key
            }
        }
        return ordered.map(\.value).joined(separator: "\n\n")
    }
}
