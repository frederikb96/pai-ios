import XCTest

@testable import PAIKit

/// The line a client puts into the composer is what the server finds an answer by, so its form is
/// held to what the backend parses: `D<n> (<title without trailing periods>): <answer>` on a line
/// of its own.
final class DecisionAnswerLineTests: XCTestCase {

    private func decision(_ number: Int, title: String) -> Decision {
        Decision(id: "d\(number)", sessionId: "s1", number: number, title: title, recommendation: "yes")
    }

    func testTheTitleLosesItsTrailingPeriodsButKeepsTheOnesInside() {
        XCTAssertEqual(
            DecisionAnswerLine.line(for: decision(3, title: "Merge the migration."), answer: "yes"),
            "D3 (Merge the migration): yes")
        XCTAssertEqual(
            DecisionAnswerLine.line(for: decision(4, title: "Bump to v1.2..."), answer: "no"),
            "D4 (Bump to v1.2): no")
    }

    func testAnAnswerSpanningLinesBecomesOneLine() {
        XCTAssertEqual(
            DecisionAnswerLine.line(for: decision(5, title: "Rename it"), answer: " no,\n  because\r\n it is late \n"),
            "D5 (Rename it): no, because it is late")
    }

    func testLinesGoAfterWhatIsWrittenSeparatedByOneBreak() {
        let lines = ["D1 (A): yes", "D2 (B): no"]
        XCTAssertEqual(DecisionAnswerLine.appending(lines, toDraft: ""), "D1 (A): yes\nD2 (B): no")
        XCTAssertEqual(
            DecisionAnswerLine.appending(lines, toDraft: "Thoughts. \n\n"), "Thoughts.\nD1 (A): yes\nD2 (B): no")
    }
}
