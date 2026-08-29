import XCTest
@testable import PAIKit

/// `SessionListFormat`'s boundaries (`>= 1_000`, `>= 1_000_000`, `<= maxLength`) are exactly where
/// an off-by-one silently changes a displayed number or truncates one character too early/late —
/// asserted here as literals, not derived from the constants under test, so retuning a threshold
/// actually breaks the test meant to catch it.
final class SessionStoreFormatTests: XCTestCase {

    // MARK: - formatTokens

    func testFormatTokensBelowOneThousandIsRawNumber() {
        XCTAssertEqual(SessionListFormat.formatTokens(999), "999")
        XCTAssertEqual(SessionListFormat.formatTokens(0), "0")
    }

    func testFormatTokensAtOneThousandSwitchesToKSuffix() {
        XCTAssertEqual(SessionListFormat.formatTokens(1_000), "1k")
        XCTAssertEqual(SessionListFormat.formatTokens(47_000), "47k")
    }

    func testFormatTokensRoundsToNearestThousand() {
        XCTAssertEqual(SessionListFormat.formatTokens(47_499), "47k")
        XCTAssertEqual(SessionListFormat.formatTokens(47_500), "48k")
    }

    func testFormatTokensBelowOneMillionStaysInKSuffix() {
        XCTAssertEqual(SessionListFormat.formatTokens(999_999), "1000k")
    }

    func testFormatTokensAtOneMillionSwitchesToMSuffix() {
        XCTAssertEqual(SessionListFormat.formatTokens(1_000_000), "1.0m")
        XCTAssertEqual(SessionListFormat.formatTokens(1_200_000), "1.2m")
    }

    // MARK: - truncate

    func testTruncateLeavesTextAtExactlyMaxLengthUntouched() {
        let text = String(repeating: "a", count: 40)
        XCTAssertEqual(SessionListFormat.truncate(text, maxLength: 40), text)
    }

    func testTruncateAddsEllipsisOneCharacterOverMaxLength() {
        let text = String(repeating: "a", count: 41)
        let result = SessionListFormat.truncate(text, maxLength: 40)
        XCTAssertEqual(result, String(repeating: "a", count: 40) + "...")
    }

    // MARK: - basename

    func testBasenameReturnsLastPathSegment() {
        XCTAssertEqual(SessionListFormat.basename("/home/frederik/Programming/pai-cloud"), "pai-cloud")
    }

    func testBasenameStripsTrailingSlash() {
        XCTAssertEqual(SessionListFormat.basename("/home/frederik/pai-cloud/"), "pai-cloud")
    }

    func testBasenameOfRootIsEmpty() {
        XCTAssertEqual(SessionListFormat.basename("/"), "")
    }

    // MARK: - displayTitle fallback chain

    func testDisplayTitlePrefersExplicitTitle() {
        let session = SessionFixture.make(title: "My session", initialMessage: "hello", workingDir: "/home/x")
        XCTAssertEqual(SessionListFormat.displayTitle(for: session), "My session")
    }

    func testDisplayTitleFallsBackToInitialMessageWhenNoTitle() {
        let session = SessionFixture.make(title: nil, initialMessage: "hello there", workingDir: "/home/x")
        XCTAssertEqual(SessionListFormat.displayTitle(for: session), "hello there")
    }

    func testDisplayTitleFallsBackToWorkingDirBasenameWhenNoInitialMessage() {
        let session = SessionFixture.make(title: nil, initialMessage: nil, workingDir: "/home/frederik/pai-cloud")
        XCTAssertEqual(SessionListFormat.displayTitle(for: session), "pai-cloud")
    }

    func testDisplayTitleFallsBackToNewSessionWhenNothingElseIsAvailable() {
        let session = SessionFixture.make(title: nil, initialMessage: nil, workingDir: nil)
        XCTAssertEqual(SessionListFormat.displayTitle(for: session), "New Session")
    }

    func testDisplayTitleTruncatesTheFallbackNotAnExplicitTitle() {
        let longMessage = String(repeating: "x", count: 60)
        let session = SessionFixture.make(title: nil, initialMessage: longMessage)
        let result = SessionListFormat.displayTitle(for: session)
        XCTAssertEqual(result, String(repeating: "x", count: 40) + "...")

        let longTitle = String(repeating: "y", count: 60)
        let titled = SessionFixture.make(title: longTitle)
        // An explicit title is never truncated — only the fallback chain is.
        XCTAssertEqual(SessionListFormat.displayTitle(for: titled), longTitle)
    }

    // MARK: - timeBucket

    func testTimeBucketIsTodayForTheSameCalendarDay() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 18))!
        let earlierToday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 3))!
        XCTAssertEqual(SessionListFormat.timeBucket(for: earlierToday, now: now, calendar: calendar), .today)
    }

    func testTimeBucketIsThisWeekForYesterday() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 8))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 6, day: 14, hour: 20))!
        XCTAssertEqual(SessionListFormat.timeBucket(for: yesterday, now: now, calendar: calendar), .thisWeek)
    }

    func testTimeBucketIsOlderPastSevenDays() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let eightDaysAgo = now.addingTimeInterval(-8 * 86_400)
        XCTAssertEqual(SessionListFormat.timeBucket(for: eightDaysAgo, now: now, calendar: calendar), .older)
    }

    func testTimeBucketJustUnderSevenDaysIsStillThisWeek() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let almostSevenDaysAgo = now.addingTimeInterval(-7 * 86_400 + 60)
        XCTAssertEqual(SessionListFormat.timeBucket(for: almostSevenDaysAgo, now: now), .thisWeek)
    }
}
