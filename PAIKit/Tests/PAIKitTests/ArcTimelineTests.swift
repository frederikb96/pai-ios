import Foundation
import XCTest

@testable import PAIKit

/// The client-side rebuild of a spec's timeline from a flat row list — `arc_rules.segments` and
/// the badge derivation the design report's §4 describes, mirrored so a client never needs a
/// second network call per segment. See `ArcTimelineBuilder`'s doc comment.
final class ArcTimelineTests: XCTestCase {

    private func row(
        id: Int, i: String? = nil, s: ArcRowStatus? = .pending, o: Double, k: ArcRowKind = .regular,
        b: Int? = nil, g: ArcLeaderAgent? = nil, v: String? = nil
    ) -> ArcRow {
        ArcRow(id: id, i: i, src: "U", diff: 1, s: s, o: o, k: k, b: b, g: g, n: nil, r: nil, v: v)
    }

    // MARK: - Segment boundary (STRICT less-than)

    /// A row whose `o` equals a marker's stays in the EARLIER segment — the strict-less-than
    /// rule the backend's own `arc-core` report says a test exists specifically to pin, because
    /// flipping the comparison moves such a row with nothing else written differently. Sized so
    /// the mutation this guards against is actually reachable: a row at exactly the marker's `o`.
    func test_rowAtMarkersOwnOrder_staysInEarlierSegment() {
        let marker = row(id: 2, s: nil, o: 5, k: .marker)
        let tiedRow = row(id: 3, o: 5, k: .leader, b: 1)
        let laterRow = row(id: 4, o: 6, k: .leader, b: 2)

        let timeline = ArcTimelineBuilder.build(rows: [marker, tiedRow, laterRow], busyAgents: [])

        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.segments[0].blocks.map(\.id), [1])
        XCTAssertEqual(timeline.segments[1].blocks.map(\.id), [2])
    }

    /// Three markers demands the boundary hold at every one of them, not just the first — a
    /// fixture with a single marker cannot tell a correct walk from one that only happens to work
    /// once.
    func test_threeMarkers_produceFourSegmentsInOrder() {
        let rows: [ArcRow] = [
            row(id: 1, o: 1, k: .leader, b: 1),
            row(id: 2, s: nil, o: 2, k: .marker),
            row(id: 3, o: 3, k: .leader, b: 2),
            row(id: 4, s: nil, o: 4, k: .marker),
            row(id: 5, o: 5, k: .leader, b: 3),
            row(id: 6, s: nil, o: 6, k: .marker),
            row(id: 7, o: 7, k: .leader, b: 4),
        ]

        let timeline = ArcTimelineBuilder.build(rows: rows, busyAgents: [])

        XCTAssertEqual(timeline.segments.count, 4)
        XCTAssertEqual(timeline.segments.map { $0.blocks.map(\.id) }, [[1], [2], [3], [4]])
        XCTAssertEqual(timeline.segments[0].marker?.id, 2)
        XCTAssertEqual(timeline.segments[1].marker?.id, 4)
        XCTAssertEqual(timeline.segments[2].marker?.id, 6)
        XCTAssertNil(timeline.segments[3].marker)
    }

    // MARK: - Blocks and loose rows

    func test_rowsShareABlock_looseRowsStayOutOfIt() {
        let leader = row(id: 1, o: 1, k: .leader, b: 10)
        let member = row(id: 2, o: 2, b: 10)
        let loose = row(id: 3, s: .done, o: 3, b: nil)

        let timeline = ArcTimelineBuilder.build(rows: [leader, member, loose], busyAgents: [])

        let segment = timeline.segments[0]
        XCTAssertEqual(segment.blocks.count, 1)
        XCTAssertEqual(segment.blocks[0].leader?.id, 1)
        XCTAssertEqual(segment.blocks[0].rows.map(\.id), [2])
        XCTAssertEqual(segment.looseRows.map(\.id), [3])
    }

    /// Within a block, member rows sort by `(o, id)` — the tie-break matters whenever two rows
    /// share an `o` written in the same payload.
    func test_blockMembers_sortByOrderThenId() {
        let leader = row(id: 1, o: 1, k: .leader, b: 1)
        let second = row(id: 5, o: 2, b: 1)
        let firstTie = row(id: 3, o: 2, b: 1)

        let timeline = ArcTimelineBuilder.build(rows: [leader, second, firstTie], busyAgents: [])

        XCTAssertEqual(timeline.segments[0].blocks[0].rows.map(\.id), [3, 5])
    }

    // MARK: - Badge state

    func test_badge_noAgentAssigned_isNotSpawned() {
        XCTAssertEqual(ArcBadgeState.of(leader: nil, busyAgents: []), .notSpawned)
        let leader = row(id: 1, s: .pending, o: 1, k: .leader, b: 1)
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: []), .notSpawned)
    }

    func test_badge_assignedButNeitherBusyNorReturned_isNotSpawned() {
        let leader = row(
            id: 1, s: .inProgress, o: 1, k: .leader, b: 1, g: ArcLeaderAgent(type: "aria", name: "arc-core"))
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: []), .notSpawned)
    }

    func test_badge_nameInBusyAgents_isWorking() {
        let leader = row(
            id: 1, s: .inProgress, o: 1, k: .leader, b: 1, g: ArcLeaderAgent(type: "aria", name: "arc-core"))
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: ["arc-core"]), .working)
    }

    func test_badge_returnedTimestampSet_isReturned() {
        let leader = row(
            id: 1, s: .inProgress, o: 1, k: .leader, b: 1,
            g: ArcLeaderAgent(type: "aria", name: "arc-core", returnedAt: "2026-09-03T20:00:00Z"))
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: []), .returned)
    }

    /// Busy wins over a stale `returnedAt` — an agent resumed by message goes back to working,
    /// per the design report's D9/§3, without the backend ever clearing the old timestamp.
    func test_badge_busyOutranksAStaleReturnedTimestamp() {
        let leader = row(
            id: 1, s: .inProgress, o: 1, k: .leader, b: 1,
            g: ArcLeaderAgent(type: "aria", name: "arc-core", returnedAt: "2026-09-03T20:00:00Z"))
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: ["arc-core"]), .working)
    }

    func test_badge_leaderDone_isAcceptedRegardlessOfBusyOrReturned() {
        let leader = row(
            id: 1, s: .done, o: 1, k: .leader, b: 1,
            g: ArcLeaderAgent(type: "aria", name: "arc-core", returnedAt: "2026-09-03T20:00:00Z"))
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: ["arc-core"]), .accepted)
    }

    func test_badge_leaderCancelled_isCancelledEvenIfNamedBusy() {
        let leader = row(
            id: 1, s: .cancelled, o: 1, k: .leader, b: 1, g: ArcLeaderAgent(type: "aria", name: "arc-core"))
        XCTAssertEqual(ArcBadgeState.of(leader: leader, busyAgents: ["arc-core"]), .cancelled)
    }

    // MARK: - notesMarkdown

    func test_notesMarkdown_joinsInNumericKeyOrder() {
        let withNotes = ArcRow(
            id: 1, i: nil, src: nil, diff: nil, s: nil, o: nil, k: nil, b: nil, g: nil,
            n: ["2": "second", "10": "tenth", "1": "first"], r: nil, v: nil
        )
        XCTAssertEqual(withNotes.notesMarkdown, "first\n\nsecond\n\ntenth")
    }

    func test_notesMarkdown_nilWhenEmpty() {
        let noNotes = ArcRow(
            id: 1, i: nil, src: nil, diff: nil, s: nil, o: nil, k: nil, b: nil, g: nil, n: [:], r: nil, v: nil)
        XCTAssertNil(noNotes.notesMarkdown)
        let missing = ArcRow(
            id: 1, i: nil, src: nil, diff: nil, s: nil, o: nil, k: nil, b: nil, g: nil, n: nil, r: nil, v: nil)
        XCTAssertNil(missing.notesMarkdown)
    }
}
