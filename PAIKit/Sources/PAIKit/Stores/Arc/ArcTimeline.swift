import Foundation

/// One of the four states an assigned block's agent badge can show — plus the fifth, `cancelled`,
/// which is not one of the contract's four (it renders greyed rather than as a stage in the
/// same progression). Derived, never stored: the backend keeps only a timestamp
/// (`g.returnedAt`) and a status letter, never a state word, so a client asking "what should the
/// badge say" always answers it fresh from those two plus whether the name is in `busyAgents`.
public enum ArcBadgeState: Sendable, Equatable {
    /// No agent has ever reported activity for this block — `g` unset, or set but with neither a
    /// busy signal nor a return timestamp (a leader assigned ahead of time, per S23: "a leader
    /// may sit unassigned for days; only activation needs the name").
    case notSpawned
    /// The named agent is in `busyAgents` right now.
    case working
    /// `g.returnedAt` is set and the agent is not currently busy — handed work back, not yet
    /// accepted (`s != .done`). An agent resumed by message goes back to `.working` on its next
    /// write; see the design report's D9/§3 for why returned is a timestamp, never a status.
    case returned
    /// The leader is `Done` — Kai read the report and accepted it.
    case accepted
    /// The leader is `Cancelled` (`X`) — S21: stopped mid-run, counted as resolved, kept in the
    /// log greyed rather than removed.
    case cancelled

    /// `leader`'s own status plus whether its named agent is in `busyAgents` — the same three
    /// facts the design report's §4 says the badge is built from (the agent's own file, its stop
    /// signal, and Kai marking the leader Done), reduced to what a client can actually read off
    /// one `ArcRow`.
    public static func of(leader: ArcRow?, busyAgents: Set<String>) -> ArcBadgeState {
        guard let leader else { return .notSpawned }
        switch leader.s {
        case .cancelled: return .cancelled
        case .done: return .accepted
        default: break
        }
        if let name = leader.g?.name, busyAgents.contains(name) { return .working }
        if leader.g?.returnedAt != nil { return .returned }
        return .notSpawned
    }
}

/// One block: its leader (if the rows carry one — always true for a well-formed spec, but this
/// stays optional rather than crashing on a spec mid-write) plus every other row sharing its
/// `b`, sorted by `(o, id)` the same way the backend orders a spec.
public struct ArcTimelineBlock: Sendable, Equatable, Identifiable {
    public let id: Int
    public let leader: ArcRow?
    public let rows: [ArcRow]
    public let badge: ArcBadgeState

    public init(id: Int, leader: ArcRow?, rows: [ArcRow], badge: ArcBadgeState) {
        self.id = id
        self.leader = leader
        self.rows = rows
        self.badge = badge
    }

    /// Mirrors `pai_cloud.arc_service.recover`'s own per-block counts exactly
    /// (`arc_service.py`'s `done`/`cancelled`/`total`) — counted separately, never folded
    /// together, so a block a caller might otherwise read as "2/2 done" cannot also show rows
    /// that were actually cancelled rather than finished. Derived from `rows` rather than read
    /// off the wire's own `ArcRecoverBlock`, since that summary exists only for the spec's
    /// currently active segment and this timeline covers every segment.
    public var done: Int { rows.filter { $0.s == .done }.count }
    public var cancelled: Int { rows.filter { $0.s == .cancelled }.count }
    public var total: Int { rows.count }
}

/// Everything between two markers (or before the first / after the last): the blocks that may
/// run together, plus any loose row belonging to none — a `P`/`D`/`X` row with no block, legal
/// per the contract's slack rules.
public struct ArcTimelineSegment: Sendable, Equatable, Identifiable {
    public var id: Int { index }
    public let index: Int
    /// The marker row that closes this segment — `nil` for the last, still-open segment, which
    /// has nothing below it yet.
    public let marker: ArcRow?
    public let blocks: [ArcTimelineBlock]
    public let looseRows: [ArcRow]

    public init(index: Int, marker: ArcRow?, blocks: [ArcTimelineBlock], looseRows: [ArcRow]) {
        self.index = index
        self.marker = marker
        self.blocks = blocks
        self.looseRows = looseRows
    }
}

public struct ArcTimeline: Sendable, Equatable {
    public let segments: [ArcTimelineSegment]

    public init(segments: [ArcTimelineSegment]) {
        self.segments = segments
    }
}

/// Builds the whole-spec timeline client-side from a flat row list — the same walk
/// `pai_cloud.arc_rules.segments` does server-side (a row's segment is how many marker rows sort
/// strictly before it), so the view never needs a second network call per segment: `recover`'s
/// `rows` dict already carries everything, and this is pure client-side grouping over it.
public enum ArcTimelineBuilder {

    /// `rows` in any order; `busyAgents` from `ArcRecoverPayload.activeSegment.busyAgents`.
    public static func build(rows: [ArcRow], busyAgents: Set<String>) -> ArcTimeline {
        let ordered = rows.sorted(by: orderedBefore)
        let markers = ordered.filter { $0.k == .marker }
        let busy = Set(busyAgents)

        // Bucket every non-marker row by its segment index first, preserving `ordered`'s sort.
        var bySegment: [Int: [ArcRow]] = [:]
        for row in ordered where row.k != .marker {
            bySegment[segmentIndex(forOrder: row.o, markers: markers), default: []].append(row)
        }

        let segmentCount = markers.count + 1
        var segments: [ArcTimelineSegment] = []
        segments.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let rowsHere = bySegment[index] ?? []
            var blocksByID: [Int: [ArcRow]] = [:]
            var loose: [ArcRow] = []
            for row in rowsHere {
                if let b = row.b {
                    blocksByID[b, default: []].append(row)
                } else {
                    loose.append(row)
                }
            }
            // Sorted by the leader's own `o` — the only ordering axis the contract has — not by
            // block id, matching the web's own sort. A block whose leader row is missing (a spec
            // mid-write) sorts by `o` 0, same as `orderedBefore`'s own fallback.
            let blocks = blocksByID.keys.map { blockID -> ArcTimelineBlock in
                let members = blocksByID[blockID] ?? []
                let leader = members.first { $0.k == .leader }
                let rest = members.filter { $0.k != .leader }
                return ArcTimelineBlock(
                    id: blockID, leader: leader, rows: rest, badge: ArcBadgeState.of(leader: leader, busyAgents: busy)
                )
            }.sorted { lhs, rhs in
                let lo = lhs.leader?.o ?? 0, ro = rhs.leader?.o ?? 0
                if lo != ro { return lo < ro }
                return lhs.id < rhs.id
            }
            segments.append(
                ArcTimelineSegment(
                    index: index, marker: index < markers.count ? markers[index] : nil, blocks: blocks, looseRows: loose
                )
            )
        }
        return ArcTimeline(segments: segments)
    }

    /// `(o, id)` — the same tie-break the backend sorts a spec's rows by, so two rows written in
    /// the same payload with equal `o` still land in a stable, reproducible order.
    static func orderedBefore(_ lhs: ArcRow, _ rhs: ArcRow) -> Bool {
        let lo = lhs.o ?? 0, ro = rhs.o ?? 0
        if lo != ro { return lo < ro }
        return lhs.id < rhs.id
    }

    /// How many marker rows sort strictly before `order` — `arc_rules.segments`' own rule,
    /// mirrored exactly: `segment(row) = count of k=M rows with o < row.o`. Deliberately
    /// STRICT-less-than, matching the backend's own pinned choice (its `arc-core` report notes a
    /// test exists specifically because flipping this to `<=` moves a row sharing a marker's `o`
    /// into the wrong segment with nothing else written differently).
    static func segmentIndex(forOrder order: Double?, markers: [ArcRow]) -> Int {
        let o = order ?? 0
        return markers.filter { ($0.o ?? 0) < o }.count
    }
}
