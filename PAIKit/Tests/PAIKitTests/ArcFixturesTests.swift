import Foundation
import XCTest

@testable import PAIKit

/// Unlike `PaiFixturesTests`, ARC's models are not mid-rewrite — so these decode the fixtures
/// into the real `Codable` types, the strongest check this corpus can offer: a field the backend
/// renamed and a fixture nobody updated to match fails here, where a plain JSON-parses check
/// would not. Shape verified against a real recover response before being written — see
/// `PaiFixtures+Arc.swift`'s own doc comment.
final class ArcFixturesTests: XCTestCase {

    func test_arcSpecsFixture_decodes() throws {
        struct Page: Decodable { let specs: [ArcSpec] }
        let page = try JSONDecoder().decode(Page.self, from: PaiFixtures.data(PaiFixtures.arcSpecs))
        XCTAssertEqual(page.specs.count, 1)
        XCTAssertEqual(page.specs[0].uuid, "3f1c9d7a-4b8e-4a2f-9c1d-7e5a2b6f0d31")
        XCTAssertEqual(page.specs[0].sessions, ["11111111-1111-1111-1111-111111111111"])
    }

    func test_arcRecoverFixture_decodes() throws {
        let payload = try JSONDecoder().decode(
            ArcRecoverPayload.self, from: PaiFixtures.data(PaiFixtures.arcRecover))
        XCTAssertEqual(payload.rows.count, 7)
        XCTAssertEqual(payload.activeSegment.index, 1)
        XCTAssertEqual(payload.activeSegment.busyAgents, ["arc-demo"])

        // `g: {"type": "kai"}` — every field past `type` absent, not merely empty.
        let kaiLeader = try XCTUnwrap(payload.rows["1"])
        XCTAssertEqual(kaiLeader.g?.type, "kai")
        XCTAssertNil(kaiLeader.g?.name)

        // The marker row: `s` genuinely null, not merely omitted.
        let marker = try XCTUnwrap(payload.rows["2"])
        XCTAssertEqual(marker.k, .marker)
        XCTAssertNil(marker.s)
        XCTAssertEqual(marker.v, "The demo spec exists and has rows.")

        // `cancelled` is counted separately from `done`/`total` — a member row this block never
        // finished but is no longer waiting on, distinct from both the other two counts.
        let buildBlock = try XCTUnwrap(payload.activeSegment.blocks.first { $0.b == 2 })
        XCTAssertEqual(buildBlock.done, 0)
        XCTAssertEqual(buildBlock.cancelled, 1)
        XCTAssertEqual(buildBlock.total, 2)
    }

    /// A leader written by hand rather than by `arc block add` (which always writes `type`) can
    /// carry a `g` with no `type` key at all — the server only requires `g` to be an object. A
    /// `type` that throws instead of decoding to `nil` here would fail this one row's decode and,
    /// since `rows` is `[String: ArcRow]` decoded as a whole, take the entire spec down with it.
    func test_arcRow_decodesLeaderAgentMissingType() throws {
        let json = """
            {
              "id": 99, "i": "Hand-written leader", "src": "U", "diff": 1, "s": "I", "o": 9.0, "k": "L",
              "b": 20, "g": {"name": "manual-agent"}, "n": {}, "r": [], "v": null
            }
            """
        let row = try JSONDecoder().decode(ArcRow.self, from: Data(json.utf8))
        XCTAssertNil(row.g?.type)
        XCTAssertEqual(row.g?.name, "manual-agent")
    }

    /// `ArcNotesPreview`'s `.lineLimit(6)` sits over a table or a fenced code block differently
    /// than over prose, since neither wraps (`MarkdownTableLayout`/`MarkdownCodeBlockLayout` are
    /// both non-wrapping, sideways-scrolling regions). This proves the corpus actually carries a
    /// note whose first block is each shape — the parse-level half of that question, provable on
    /// Linux; whether it *reads* sensibly truncated stays a rendering judgement PORTING.md tracks.
    func test_arcRecoverFixture_notesCoverTableAndCodeBlockFirst() throws {
        let payload = try JSONDecoder().decode(
            ArcRecoverPayload.self, from: PaiFixtures.data(PaiFixtures.arcRecover))

        let tableFirst = try XCTUnwrap(payload.rows["5"]?.notesMarkdown)
        guard case .table = try XCTUnwrap(MarkdownParser.parse(tableFirst).first) else {
            return XCTFail("expected row 5's notes to start with a table block")
        }

        let codeBlockFirst = try XCTUnwrap(payload.rows["8"]?.notesMarkdown)
        guard case .codeBlock = try XCTUnwrap(MarkdownParser.parse(codeBlockFirst).first) else {
            return XCTFail("expected row 8's notes to start with a fenced code block")
        }
    }

    /// Bridges the fixture into `ArcTimelineBuilder` — decoding correctly and building the right
    /// timeline from what was decoded are two different claims, and a bug in the wiring between
    /// them (the wrong field read into `ArcTimelineBuilder.build`'s arguments) would pass both
    /// halves tested alone.
    func test_arcRecoverFixture_buildsExpectedTimeline() throws {
        let payload = try JSONDecoder().decode(
            ArcRecoverPayload.self, from: PaiFixtures.data(PaiFixtures.arcRecover))
        let timeline = ArcTimelineBuilder.build(
            rows: Array(payload.rows.values), busyAgents: Set(payload.activeSegment.busyAgents))

        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.segments[0].blocks.map(\.id), [1])
        XCTAssertEqual(timeline.segments[0].blocks[0].badge, .accepted)
        XCTAssertNotNil(timeline.segments[0].marker)

        let secondSegment = timeline.segments[1]
        XCTAssertEqual(secondSegment.blocks.map(\.id).sorted(), [2, 3])
        XCTAssertEqual(secondSegment.looseRows.map(\.id), [7])
        let workingBlock = try XCTUnwrap(secondSegment.blocks.first { $0.id == 2 })
        XCTAssertEqual(workingBlock.badge, .working)
        let notSpawnedBlock = try XCTUnwrap(secondSegment.blocks.first { $0.id == 3 })
        XCTAssertEqual(notSpawnedBlock.badge, .notSpawned)
    }
}
