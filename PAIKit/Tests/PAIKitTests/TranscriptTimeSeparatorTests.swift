import XCTest

@testable import PAIKit

/// The separator decides a row's height, so what it answers has to depend on nothing but the two
/// timestamps — anything else and the same window measures differently on two passes, which is a
/// row changing height under the reader.
final class TranscriptTimeSeparatorTests: XCTestCase {

    private let noon = Date(timeIntervalSince1970: 1_756_000_000)

    private func later(_ seconds: TimeInterval) -> Date { noon.addingTimeInterval(seconds) }

    /// A burst of tool calls is one stretch of work, not a series of moments worth stamping.
    func testARapidRunOfRowsCarriesNoSeparator() {
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: noon, current: later(1)), .none)
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: noon, current: later(14 * 60)), .none)
    }

    /// The boundary itself, from both sides — an input in the middle of the range cannot tell a
    /// fifteen-minute rule from any other.
    func testTheQuietIntervalIsTheBoundary() {
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: noon, current: later(15 * 60 - 1)), .none)
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: noon, current: later(15 * 60)), .time)
    }

    /// A new day says so even when the pause was short — two rows a minute apart across midnight
    /// are further apart than the clock alone shows.
    func testADayChangeShowsTheDateEvenAfterAShortPause() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 18
        components.hour = 23
        components.minute = 59
        let calendar = Calendar.current
        guard let lateNight = calendar.date(from: components) else {
            return XCTFail("could not build the fixture date")
        }

        XCTAssertEqual(
            TranscriptTimeSeparator.style(previous: lateNight, current: lateNight.addingTimeInterval(120)),
            .dateAndTime)
    }

    /// The top of the loaded window always shows one: the reader who scrolled up there is exactly
    /// the reader asking when this was.
    func testTheFirstRowOfTheWindowAlwaysShowsOne() {
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: nil, current: noon), .dateAndTime)
    }

    /// A row with no timestamp of its own has nothing to say, whatever came before it — a pending
    /// bubble is the real case.
    func testARowWithNoTimestampShowsNothing() {
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: noon, current: nil), .none)
        XCTAssertEqual(TranscriptTimeSeparator.style(previous: nil, current: nil), .none)
    }

    /// The wire shape the transcript actually carries, fraction and numeric offset included —
    /// a formatter that rejects it would report every pair as a first row.
    func testItReadsTheBackendsOwnTimestampShape() {
        XCTAssertEqual(
            TranscriptTimeSeparator.style(
                previousTimestamp: "2026-09-18T23:10:00.506812+00:00",
                currentTimestamp: "2026-09-18T23:40:00.506812+00:00"),
            .time)
        XCTAssertEqual(
            TranscriptTimeSeparator.style(
                previousTimestamp: "2026-09-18T23:10:00.506812+00:00",
                currentTimestamp: "2026-09-18T23:12:00.506812+00:00"),
            .none)
    }
}
