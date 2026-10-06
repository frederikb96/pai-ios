import Foundation
import XCTest

@testable import PAIKit

/// A note body can be written by anyone holding an edit link, so the wikilink scan has to stay
/// linear in the body whatever it says. Two things are held here: the hand-written scanners find
/// exactly what the `Regex` patterns they replaced found (the patterns below are the reference),
/// and cap-sized hostile bodies from `Resources/notes-link-scaling.json` scan within a time
/// budget. That file is a byte-identical copy of pai-cloud's `shared/notes-link-scaling.json`,
/// the fixture every note tokeniser's scaling test shares: change it there first, then copy it.
final class NoteWikilinkScanTests: XCTestCase {

    // MARK: - The reference: the patterns and the code-range logic the scanners replaced

    private enum Reference {
        static func codeRanges(in body: String) -> [Range<Int>] {
            let fencePrefix = /^[ \t]{0,3}(`{3,}|~{3,})/
            let spanPattern = /(`+)([^`\n]*?)\1/
            var ranges: [Range<Int>] = []
            var openFence: (char: Character, len: Int, start: Int)?
            var offset = 0
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() {
                let hasNewline = index < lines.count - 1
                if let match = try? fencePrefix.firstMatch(in: line) {
                    let fenceRun = String(match.output.1)
                    let fenceChar = fenceRun.first!
                    let fenceLen = fenceRun.count
                    if let open = openFence {
                        if fenceChar == open.char, fenceLen >= open.len {
                            ranges.append(open.start..<(hasNewline ? offset + line.count + 1 : offset + line.count))
                            openFence = nil
                        }
                    } else {
                        openFence = (fenceChar, fenceLen, offset)
                    }
                }
                offset += line.count + (hasNewline ? 1 : 0)
            }
            if let open = openFence { ranges.append(open.start..<body.count) }
            for match in body.matches(of: spanPattern) {
                let start = body.distance(from: body.startIndex, to: match.range.lowerBound)
                let end = body.distance(from: body.startIndex, to: match.range.upperBound)
                ranges.append(start..<end)
            }
            return ranges
        }

        static func wikilinkMatches(in body: String) -> [WikilinkScan.Match] {
            let wikilinkPattern = /(!)?\[\[([^\]|#\n]+)(#[^\]|\n]+)?(\|[^\]\n]+)?\]\]/
            return body.matches(of: wikilinkPattern).map { match in
                func offsets(_ r: Range<String.Index>) -> Range<Int> {
                    body.distance(
                        from: body.startIndex, to: r.lowerBound)..<body.distance(
                            from: body.startIndex, to: r.upperBound)
                }
                let whole = offsets(match.range)
                let (_, bang, target, heading, alias) = match.output
                return WikilinkScan.Match(
                    start: whole.lowerBound, end: whole.upperBound, isEmbed: bang != nil,
                    target: offsets(target.startIndex..<target.endIndex),
                    anchor: heading.map { offsets($0.startIndex..<$0.endIndex) },
                    alias: alias.map { offsets($0.startIndex..<$0.endIndex) })
            }
        }

        static func findWikilinks(_ body: String) -> [Wikilink] {
            let excluded = codeRanges(in: body)
            return wikilinkMatches(in: body).compactMap { m in
                if excluded.contains(where: { $0.contains(m.start) }) { return nil }
                let chars = Array(body)
                return Wikilink(
                    start: m.start, end: m.end, isEmbed: m.isEmbed, target: String(chars[m.target]),
                    heading: m.anchor.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) },
                    alias: m.alias.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) })
            }
        }
    }

    // MARK: - Differential

    /// A small seeded generator, so a failing body is reproducible.
    private struct Lcg {
        var state: UInt32
        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state) / 4_294_967_296
        }
    }

    private static func randomBodies(count: Int, alphabet: [String]) -> [String] {
        var rng = Lcg(state: 20_261_005)
        return (0..<count).map { _ in
            let length = Int(rng.next() * 16)
            return (0..<length).map { _ in alphabet[Int(rng.next() * Double(alphabet.count))] }.joined()
        }
    }

    /// Every sequence of up to `length` fragments: the cases where the engine has to choose are
    /// too rare among random bodies to rely on them.
    private static func allSequences(_ fragments: [String], length: Int) -> [String] {
        var level = [""]
        var out = [""]
        for _ in 0..<length {
            level = level.flatMap { prefix in fragments.map { prefix + $0 } }
            out.append(contentsOf: level)
        }
        return out
    }

    // A CRLF and a combining mark are one Character each, which is what the Regex sees and a
    // UTF-16 scan would not.
    private static let characters = [
        "[", "[", "]", "]", "!", "|", "#", "\n", " ", "`", "a", "~", "\t", "\r\n", "\u{301}", "é",
    ]
    private static let fragments = [
        "[[", "]]", "![[", "[", "]", "#", "|", "\n", "`", "``", "```", "~~~", "a", "b c", " ", "\r\n", "\u{301}",
    ]

    /// Built once per process; the exhaustive sets are sized so that the three differential tests
    /// together stay at about a minute in a debug build, where `Regex` is slow.
    private static let cases: [String] =
        randomBodies(count: 10_000, alphabet: characters)
        + randomBodies(count: 10_000, alphabet: fragments)
        + allSequences(["[[", "]]", "#", "|", "a", "\n", "!"], length: 5)
        + allSequences(["`", "``", "a", "\n"], length: 6)
        + allSequences(["```", "~~~", "`", "\n", " ", "a"], length: 5)
        + allSequences(["[[", "]]", "`", "\r\n", "\u{301}", "#"], length: 4)

    /// The bodies on which `actual` disagrees with `expected`, a few at most.
    private func disagreements<T: Equatable>(
        _ expected: (String) -> T, _ actual: (String) -> T
    ) -> [String] {
        var out: [String] = []
        for body in Self.cases where actual(body) != expected(body) {
            out.append(body.debugDescription)
            if out.count == 5 { break }
        }
        return out
    }

    func testWikilinkScannerFindsExactlyWhatThePatternFinds() {
        XCTAssertGreaterThan(Self.cases.count, 40_000, "the case set looks truncated")
        XCTAssertEqual(
            disagreements(
                { Reference.wikilinkMatches(in: $0) }, { WikilinkScan.wikilinks(in: Array($0)) }), [])
    }

    func testCodeRangesAreExactlyThoseTheOldScanFound() {
        XCTAssertEqual(
            disagreements({ Reference.codeRanges(in: $0) }, { WikilinkScan.codeRanges(in: Array($0)) }), [])
    }

    func testFindWikilinksAgreesWithTheOldImplementation() {
        XCTAssertEqual(disagreements({ Reference.findWikilinks($0) }, { findWikilinks($0) }), [])
    }

    func testExcludedIsMembershipInTheUnionOfRanges() {
        // Overlapping, nested, adjacent and out-of-order ranges, where merging has to choose.
        let ranges = [20..<25, 0..<4, 3..<8, 4..<6, 8..<9, 30..<30, 12..<15, 14..<18]
        let excluded = WikilinkScan.Excluded(ranges)
        for pos in -1..<40 {
            XCTAssertEqual(excluded.contains(pos), ranges.contains { $0.contains(pos) }, "position \(pos)")
        }
    }

    // MARK: - Scaling

    private struct ScalingFixture: Decodable {
        struct Case: Decodable {
            let name: String
            let prefix: String
            let unit: String
            let repeatCount: Int
            let suffix: String
            enum CodingKeys: String, CodingKey {
                case name, prefix, unit, suffix
                case repeatCount = "repeat"
            }
        }
        let cases: [Case]
    }

    /// Runs `work` on its own thread and reports whether it finished within `seconds`. A thread
    /// that runs over cannot be cancelled, so a regression fails here instead of hanging the
    /// suite, and the runaway thread dies with the test process.
    private func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread {
            work()
            done.signal()
        }
        thread.stackSize = 64 << 20
        thread.start()
        return done.wait(timeout: .now() + seconds) == .success
    }

    func testCapSizedHostileBodiesScanInLinearTime() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/notes-link-scaling.json")
        let fixture = try JSONDecoder().decode(ScalingFixture.self, from: Data(contentsOf: path))
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10, "fixture file looks truncated")
        for c in fixture.cases {
            let body = c.prefix + String(repeating: c.unit, count: c.repeatCount) + c.suffix
            XCTAssertGreaterThan(body.utf8.count, 400_000, "\(c.name) is not cap-sized")
            let started = Date()
            let finished = finishes(within: 20) {
                _ = findWikilinks(body)
                _ = splitBodyForRender(body, nameToId: [:])
            }
            guard finished else {
                XCTFail("\(c.name): not scanned within 20 s")
                return  // the runaway thread is still burning a core; do not start another
            }
            print("scaling \(c.name): \(Date().timeIntervalSince(started)) s")
        }
    }

    /// The links a body full of links yields must not cost a pass over the body each.
    func testManyLinksAreLinear() {
        let body = String(repeating: "[[a]] ", count: 80_000)
        XCTAssertTrue(
            finishes(within: 20) {
                XCTAssertEqual(findWikilinks(body).count, 80_000)
                _ = splitBodyForRender(body, nameToId: [:])
            }, "80k links not scanned within 20 s")
    }
}
