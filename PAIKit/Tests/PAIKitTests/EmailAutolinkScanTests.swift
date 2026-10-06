import Foundation
import XCTest

@testable import PAIKit

/// Text in a note or a message reaches the email autolink scan whole, so it has to stay linear in
/// the text whatever it says: a pasted blob is one long run of local-part characters. The scan is
/// held to the `NSRegularExpression` it replaced, which is the reference here, and to a time
/// budget on cap-sized bodies.
final class EmailAutolinkScanTests: XCTestCase {

    private static let reference = try! NSRegularExpression(
        pattern:
            #"[A-Za-z0-9+_.-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+"#
    )

    private func referenceMatches(_ text: String) -> [NSRange] {
        Self.reference.matches(in: text, range: NSRange(text.startIndex..., in: text)).map(\.range)
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

    // Non-ASCII letters and a surrogate pair are not in any class; a combining mark follows a
    // class member without being one.
    private static let pieces = [
        "a", "Z", "9", "+", "_", ".", "-", "@", "@", " ", "\n", "é", "\u{301}", "😀", "com", "x@y.z", ".-", "-.",
        "b-", "a@b.com", "+x@c.org",
    ]

    private static let cases: [String] = {
        var rng = Lcg(state: 20_261_006)
        let random = (0..<60_000).map { _ -> String in
            let length = Int(rng.next() * 14)
            return (0..<length).map { _ in pieces[Int(rng.next() * Double(pieces.count))] }.joined()
        }
        // Every arrangement of the characters that decide a match: where the `@` falls, whether a
        // label ends in `-`, an empty label, a second `@`, something the classes refuse.
        let exhaustive = allSequences(["a", "@", ".", "-", "+", " ", "é"], length: 7)
        return random + exhaustive
    }()

    func testScanFindsExactlyWhatThePatternFinds() {
        XCTAssertGreaterThan(Self.cases.count, 500_000, "the case set looks truncated")
        var disagreements: [String] = []
        for text in Self.cases {
            let expected = referenceMatches(text)
            let actual = EmailAutolinkScan.matches(in: text)
            if actual != expected {
                disagreements.append("\(text.debugDescription): expected \(expected), got \(actual)")
                if disagreements.count == 5 { break }
            }
        }
        XCTAssertEqual(disagreements, [])
    }

    /// A match that ends mid-run leaves the rest of the run free to start the next one.
    func testALocalPartMayStartWhereAnEarlierMatchEnded() {
        let text = "a@b.com+x@c.org"
        XCTAssertEqual(EmailAutolinkScan.matches(in: text), referenceMatches(text))
        XCTAssertEqual(EmailAutolinkScan.matches(in: text).count, 2)
    }

    private func links(in text: String) -> [String] {
        for block in MarkdownParser.parse(text, options: MarkdownParser.defaultOptions) {
            if case .paragraph(let content) = block { return content.runs.compactMap(\.destination) }
        }
        return []
    }

    /// A URL covering an address wins, and the addresses on either side of it stay links.
    func testAnAddressInsideAUrlIsNotASecondLink() {
        XCTAssertEqual(
            links(in: "a@b.co see https://user@example.com/x then me@x.org and c@d.io"),
            ["mailto:a@b.co", "https://user@example.com/x", "mailto:me@x.org", "mailto:c@d.io"])
    }

    /// Many addresses and URLs interleaved, so the overlap check is made against a long URL list.
    func testManyAddressesAndUrlsLinkInOrder() {
        let text = String(repeating: "a@b.co http://x.y/z@w.v ", count: 3_000)
        let found = links(in: text)
        XCTAssertEqual(found.count, 6_000)
        XCTAssertEqual(Array(found.prefix(2)), ["mailto:a@b.co", "http://x.y/z@w.v"])
    }

    func testCapSizedHostileTextsScanInLinearTime() {
        let cap = 524_288
        let shapes: [(String, String)] = [
            ("letters", "a"), ("dots", "."), ("local punctuation", "+"), ("hyphens", "-"),
            ("local then at", "a@"), ("at then label", "a@b"), ("dotted labels", "a@b."),
            ("labels ending in hyphen", "a@b-"), ("bare at", "@"), ("addresses", "a@b.c "),
            ("chained addresses", "a@b.c+"),
        ]
        for (name, unit) in shapes {
            let text = String(repeating: unit, count: cap / unit.count)
            let done = DispatchSemaphore(value: 0)
            let started = Date()
            let thread = Thread {
                _ = EmailAutolinkScan.matches(in: text)
                _ = MarkdownParser.parse(text, options: MarkdownParser.defaultOptions)
                done.signal()
            }
            thread.stackSize = 64 << 20
            thread.start()
            guard done.wait(timeout: .now() + 20) == .success else {
                XCTFail("\(name): not scanned within 20 s")
                return  // the runaway thread is still burning a core; do not start another
            }
            print("scaling \(name): \(Date().timeIntervalSince(started)) s")
        }
    }
}
