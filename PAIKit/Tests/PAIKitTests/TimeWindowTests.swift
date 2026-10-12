import XCTest

@testable import PAIKit

/// Windows are resolved in the zone of the calendar they are given, so every case pins one:
/// Berlin has a UTC offset and a daylight-saving change, which is what a "local midnight" rule
/// can get wrong.
final class TimeWindowTests: XCTestCase {

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    /// 2026-10-12 15:30 in Berlin (UTC+2).
    private var now: Date { berlin.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 15, minute: 30))! }

    private func day(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let parts = berlin.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d", parts.year!, parts.month!, parts.day!, parts.hour!, parts.minute!)
    }

    // MARK: - Presets

    func testTodayStartsAtLocalMidnightAndEndsNow() {
        let bounds = TimeWindow.preset(.today).bounds(now: now, calendar: berlin)
        XCTAssertEqual(day(bounds.since), "2026-10-12 00:00")
        XCTAssertEqual(bounds.until, now)
    }

    func testSinceYesterdayStartsAtYesterdaysLocalMidnight() {
        let bounds = TimeWindow.preset(.sinceYesterday).bounds(now: now, calendar: berlin)
        XCTAssertEqual(day(bounds.since), "2026-10-11 00:00")
    }

    /// Hours, not calendar days: the rolling presets are `now - N x 24 h` across the clock change
    /// on 2026-10-25.
    func testRollingPresetsCountHoursNotCalendarDays() {
        let late = berlin.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
        let bounds = TimeWindow.preset(.last7Days).bounds(now: late, calendar: berlin)
        XCTAssertEqual(bounds.since, late.addingTimeInterval(-7 * 24 * 3600))
        XCTAssertEqual(
            TimeWindow.preset(.last30Days).bounds(now: late, calendar: berlin).since,
            late.addingTimeInterval(-30 * 24 * 3600))
    }

    // MARK: - Slider

    func testTheSliderAxisEndsAtTodaysMidnightAndStepsBackInWeeks() {
        XCTAssertEqual(day(TimeWindowSlider.date(forStop: 52, now: now, calendar: berlin)), "2026-10-12 00:00")
        XCTAssertEqual(day(TimeWindowSlider.date(forStop: 51, now: now, calendar: berlin)), "2026-10-05 00:00")
        XCTAssertEqual(day(TimeWindowSlider.date(forStop: 0, now: now, calendar: berlin)), "2025-10-13 00:00")
    }

    func testTheFullSliderRangeRunsFromFiftyTwoWeeksAgoUntilNow() {
        let bounds = TimeWindow.fromSlider(.full, now: now, calendar: berlin).bounds(now: now, calendar: berlin)
        XCTAssertEqual(day(bounds.since), "2025-10-13 00:00")
        XCTAssertEqual(bounds.until, now)
    }

    /// An end thumb short of the right edge covers the whole of its day.
    func testASliderEndBeforeTheEdgeIsTheEndOfThatDay() {
        let bounds = TimeWindow.fromSlider(SliderSelection(from: 40, to: 50), now: now, calendar: berlin).bounds(
            now: now, calendar: berlin)
        XCTAssertEqual(day(bounds.since), "2026-07-20 00:00")
        let until = try! XCTUnwrap(bounds.until)
        XCTAssertEqual(day(until), "2026-09-28 23:59")
        XCTAssertLessThan(until, berlin.date(from: DateComponents(year: 2026, month: 9, day: 29))!)
    }

    func testASelectionCanNeverCollapseOrInvert() {
        XCTAssertEqual(SliderSelection(from: 30, to: 30), SliderSelection(from: 30, to: 31))
        XCTAssertEqual(SliderSelection(from: 60, to: 70), SliderSelection(from: 51, to: 52))
        XCTAssertEqual(SliderSelection(from: -4, to: 10), SliderSelection(from: 0, to: 10))
    }

    func testDraggingAThumbStopsOneStopShortOfTheOther() {
        let selection = SliderSelection(from: 10, to: 20)
        XCTAssertEqual(TimeWindowSlider.movingStart(of: selection, to: 45), SliderSelection(from: 19, to: 20))
        XCTAssertEqual(TimeWindowSlider.movingEnd(of: selection, to: 2), SliderSelection(from: 10, to: 11))
    }

    func testATouchMovesTheNearerThumb() {
        let selection = SliderSelection(from: 10, to: 40)
        XCTAssertTrue(TimeWindowSlider.movesStart(touchStop: 14, selection: selection))
        XCTAssertFalse(TimeWindowSlider.movesStart(touchStop: 35, selection: selection))
        // Both thumbs a stop apart, touch beyond them on either side.
        let tight = SliderSelection(from: 20, to: 21)
        XCTAssertTrue(TimeWindowSlider.movesStart(touchStop: 5, selection: tight))
        XCTAssertFalse(TimeWindowSlider.movesStart(touchStop: 50, selection: tight))
    }

    func testFractionsRoundToTheNearestStopAndClamp() {
        XCTAssertEqual(TimeWindowSlider.stop(forFraction: -0.3), 0)
        XCTAssertEqual(TimeWindowSlider.stop(forFraction: 0.5), 26)
        XCTAssertEqual(TimeWindowSlider.stop(forFraction: 7), 52)
    }

    func testMonthMarksNameTheFirstStopOfEachMonth() {
        let marks = TimeWindowSlider.monthMarks(now: now, calendar: berlin)
        XCTAssertEqual(marks.first?.stop, 0)
        XCTAssertEqual(marks.first?.month, 10)
        XCTAssertEqual(marks.first?.year, 2025)
        XCTAssertEqual(marks.filter(\.showsYear).map(\.month), [10, 1])
        XCTAssertEqual(marks.map(\.month).first(where: { $0 == 11 }), 11)
        XCTAssertEqual(marks.map(\.stop), marks.map(\.stop).sorted())
        // Twelve months boundaries plus the leading partial month.
        XCTAssertGreaterThanOrEqual(marks.count, 12)
    }

    // MARK: - Custom

    func testACustomWindowCoversBothEndDaysWhole() {
        let window = TimeWindow.custom(
            from: CalendarDay(year: 2026, month: 3, day: 1), to: CalendarDay(year: 2026, month: 3, day: 31))
        let bounds = window.bounds(now: now, calendar: berlin)
        XCTAssertEqual(day(bounds.since), "2026-03-01 00:00")
        XCTAssertEqual(day(bounds.until), "2026-03-31 23:59")
        XCTAssertTrue(
            bounds.contains(berlin.date(from: DateComponents(year: 2026, month: 3, day: 31, hour: 23, minute: 59))!))
        XCTAssertFalse(bounds.contains(berlin.date(from: DateComponents(year: 2026, month: 4, day: 1))!))
    }

    func testCalendarDayParsesOnlyStrictIsoOrder() {
        XCTAssertEqual(CalendarDay(isoString: "2026-03-01"), CalendarDay(year: 2026, month: 3, day: 1))
        XCTAssertNil(CalendarDay(isoString: "01.03.2026"))
        XCTAssertNil(CalendarDay(isoString: "2026-3-1"))
        XCTAssertNil(CalendarDay(isoString: "2026-02-30"))
        XCTAssertNil(CalendarDay(isoString: "2026-13-01"))
        XCTAssertEqual(CalendarDay(year: 987, month: 3, day: 1).isoString, "0987-03-01")
    }

    // MARK: - Labels and wire

    func testLabelsFollowTheSpecWording() {
        XCTAssertEqual(TimeWindow.preset(.last7Days).label(now: now, calendar: berlin), "Last 7 days")
        XCTAssertEqual(
            TimeWindow.custom(
                from: CalendarDay(year: 2026, month: 3, day: 1), to: CalendarDay(year: 2026, month: 3, day: 9)
            )
            .label(now: now, calendar: berlin),
            "2026-03-01 – 2026-03-09")
        XCTAssertEqual(
            TimeWindow.fromSlider(.full, now: now, calendar: berlin).label(now: now, calendar: berlin),
            "2025-10-13 – now")
        XCTAssertEqual(
            TimeWindow.fromSlider(SliderSelection(from: 40, to: 50), now: now, calendar: berlin).label(
                now: now, calendar: berlin),
            "2026-07-20 – 2026-09-28")
    }

    func testOpeningTheSliderWithoutASliderWindowSelectsTheWholeAxis() {
        XCTAssertEqual(TimeWindow.preset(.today).sliderSelection(now: now, calendar: berlin), .full)
    }

    /// A slider window is its days: the same window read a week later means the same dates, and
    /// reopening the overlay then puts the thumbs on the stops those days are now nearest to.
    func testASliderWindowKeepsItsDatesAsTimePasses() {
        let chosen = TimeWindow.fromSlider(SliderSelection(from: 40, to: 50), now: now, calendar: berlin)
        let later = now.addingTimeInterval(7 * 86_400)

        XCTAssertEqual(chosen.bounds(now: later, calendar: berlin), chosen.bounds(now: now, calendar: berlin))
        XCTAssertEqual(chosen.label(now: later, calendar: berlin), "2026-07-20 – 2026-09-28")
        XCTAssertEqual(chosen.sliderSelection(now: now, calendar: berlin), SliderSelection(from: 40, to: 50))
        XCTAssertEqual(chosen.sliderSelection(now: later, calendar: berlin), SliderSelection(from: 39, to: 49))
    }

    /// The open right edge stays open: it means "until now" whenever the query runs.
    func testAnOpenSliderEndFollowsNow() {
        let chosen = TimeWindow.fromSlider(SliderSelection(from: 20, to: 52), now: now, calendar: berlin)
        let later = now.addingTimeInterval(3 * 86_400)
        XCTAssertEqual(chosen.bounds(now: later, calendar: berlin).until, later)
        XCTAssertEqual(chosen.sliderSelection(now: later, calendar: berlin).to, 52)
    }

    func testAWindowOlderThanTheAxisReopensAtTheLeftEdge() {
        let chosen = TimeWindow.slider(from: CalendarDay(year: 2020, month: 1, day: 1), to: nil)
        XCTAssertEqual(chosen.sliderSelection(now: now, calendar: berlin).from, 0)
    }

    func testTheWireStringIsUtcWithAnOffset() {
        XCTAssertEqual(
            TimeBounds.wireString(Date(timeIntervalSince1970: 1_800_000_000)), "2027-01-15T08:00:00.000+00:00")
    }

    func testBoundsFilterAnEpochMillisecondStamp() {
        let bounds = TimeBounds(
            since: Date(timeIntervalSince1970: 100), until: Date(timeIntervalSince1970: 200))
        XCTAssertTrue(bounds.contains(epochMilliseconds: 100_000))
        XCTAssertTrue(bounds.contains(epochMilliseconds: 200_000))
        XCTAssertFalse(bounds.contains(epochMilliseconds: 99_999))
        XCTAssertFalse(bounds.contains(epochMilliseconds: 200_001))
    }
}
