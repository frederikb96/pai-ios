import Foundation
import XCTest

@testable import PAIKit

/// `parseOutline` runs over a note body that anyone holding an edit link can write. The heading
/// pattern `^(#{1,6})\s+(.+?)\s*$` is quadratic on a heading line followed by a long run of
/// whitespace, so the scan is hand-written; this holds it to the pattern it replaced and to a
/// time budget.
final class NoteOutlineScanTests: XCTestCase {

    /// The reference: `parseOutline` as it was written over the pattern.
    private func referenceOutline(_ body: String) -> [OutlineEntry] {
        let headingPattern = /^(#{1,6})\s+(.+?)\s*$/
        var entries: [OutlineEntry] = []
        var offset = 0
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = try? headingPattern.firstMatch(in: line) {
                entries.append(OutlineEntry(level: match.output.1.count, text: String(match.output.2), offset: offset))
            }
            offset += line.count + 1
        }
        return entries
    }

    private struct Lcg {
        var state: UInt32
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
    }

    private static func allSequences(_ fragments: [String], length: Int) -> [String] {
        var level = [""]
        var out = [""]
        for _ in 0..<length {
            level = level.flatMap { prefix in fragments.map { prefix + $0 } }
            out.append(contentsOf: level)
        }
        return out
    }

    // Whitespace that is and is not a line break to the pattern's `.`, and a combining mark that
    // changes what a Character is.
    private static let pieces = [
        "#", "##", "#######", " ", "\t", "\u{a0}", "\u{2028}", "\r", "\r\n", "\u{85}", "\u{b}", "\u{301}",
        "a", "bc", "é", "\n",
    ]

    private static let cases: [String] = {
        var rng = Lcg(state: 20_261_005)
        let random = (0..<20_000).map { _ -> String in
            let length = Int(rng.next() * 12)
            return (0..<length).map { _ in pieces[Int(rng.next() * Double(pieces.count))] }.joined()
        }
        return random + allSequences(["#", " ", "a", "\u{2028}", "\r\n", "\n", "\u{a0}"], length: 6)
    }()

    func testOutlineAgreesWithThePatternItReplaced() {
        XCTAssertGreaterThan(Self.cases.count, 40_000, "the case set looks truncated")
        var disagreements: [String] = []
        for body in Self.cases where parseOutline(body) != referenceOutline(body) {
            disagreements.append(body.debugDescription)
            if disagreements.count == 5 { break }
        }
        XCTAssertEqual(disagreements, [])
    }

    func testHeadingFollowedByALongWhitespaceRunScansInLinearTime() {
        for body in [
            "# a" + String(repeating: " ", count: 524_288) + "b",
            "#" + String(repeating: " ", count: 524_288),
            String(repeating: "# a" + String(repeating: " ", count: 64) + "b\n", count: 8_192),
        ] {
            let done = DispatchSemaphore(value: 0)
            let thread = Thread {
                _ = parseOutline(body)
                done.signal()
            }
            thread.stackSize = 64 << 20
            thread.start()
            XCTAssertEqual(done.wait(timeout: .now() + 20), .success, "outline not scanned within 20 s")
        }
    }
}
