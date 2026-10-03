import XCTest

@testable import PAIKit

/// The server owns the pace line and the steps; the client's whole job is decoding the level and
/// painting it, per window, with "no line" staying neutral.
final class UsagePaceTests: XCTestCase {

    private func decode(_ json: String) throws -> Usage {
        try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    }

    func testEachLevelPaintsItsOwnToneInOrder() throws {
        let usage = try decode(
            """
            {"five_hour": {"utilization": 30, "resets_at": "2026-10-03T12:20:00.207264+00:00",
               "pace": {"line_percent": 25.0, "delta_points": 5.0, "level": "slightly_over"}},
             "seven_day": {"utilization": 12, "resets_at": "2026-10-09T18:00:00.207283+00:00",
               "pace": {"line_percent": 14.3, "delta_points": -2.3, "level": "on_pace"}}}
            """)
        XCTAssertEqual(usage.fiveHour?.paceTone, .yellow)
        XCTAssertEqual(usage.sevenDay?.paceTone, .green)
        XCTAssertEqual(
            [UsagePaceLevel.onPace, .slightlyOver, .over, .farOver].map {
                UsageWindow(
                    utilization: 1, resetsAt: nil,
                    pace: UsagePace(linePercent: 0, deltaPoints: 0, level: $0)
                ).paceTone
            },
            [.green, .yellow, .orange, .red])
    }

    func testAWindowWithoutALineIsNeutralWhetherNullAbsentOrUnknownLevel() throws {
        let usage = try decode(
            """
            {"five_hour": {"utilization": 95, "resets_at": null, "pace": null},
             "seven_day": {"utilization": 95, "resets_at": "2026-10-09T18:00:00+00:00"}}
            """)
        XCTAssertNil(usage.fiveHour?.resetsAt)
        XCTAssertEqual(usage.fiveHour?.paceTone, .neutral)
        XCTAssertEqual(usage.sevenDay?.paceTone, .neutral)

        let future = try decode(
            """
            {"five_hour": {"utilization": 5, "resets_at": "2026-10-03T12:20:00+00:00",
               "pace": {"line_percent": 1, "delta_points": 4, "level": "scorching"}}}
            """)
        XCTAssertEqual(future.fiveHour?.paceTone, .neutral)
    }

    func testDescriptionSaysWhichSideOfTheLine() {
        let over = UsageWindow(
            utilization: 30, resetsAt: nil, pace: UsagePace(linePercent: 25, deltaPoints: 5, level: .over))
        let under = UsageWindow(
            utilization: 12, resetsAt: nil, pace: UsagePace(linePercent: 14.3, deltaPoints: -2.3, level: .onPace))
        XCTAssertEqual(over.paceDescription, "5 points over a steady pace of 25%")
        XCTAssertEqual(under.paceDescription, "2 points under a steady pace of 14%")
        XCTAssertNil(UsageWindow(utilization: 1, resetsAt: nil).paceDescription)
    }

    /// A cleared gate must reach the server as `null`; an omitted key would leave the old value.
    func testClearedPaceGatesAreSentAsNull() throws {
        var fields = TaskWriteFields.fresh(timezone: "UTC")
        fields.sessionPaceGatePoints = 5
        let set = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) as? [String: Any]
        XCTAssertEqual(set?["session_pace_gate_points"] as? Int, 5)

        fields.sessionPaceGatePoints = nil
        let cleared = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fields)) as? [String: Any]
        XCTAssertTrue(cleared?["session_pace_gate_points"] is NSNull)
        XCTAssertTrue(cleared?["weekly_pace_gate_points"] is NSNull)
        XCTAssertTrue(cleared?["max_runtime_minutes"] is NSNull)
    }
}
