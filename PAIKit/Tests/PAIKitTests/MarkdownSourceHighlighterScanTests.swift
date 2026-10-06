import Foundation
import XCTest

@testable import PAIKit

/// The source highlighter runs on every keystroke over a note anyone holding an edit link may have
/// written, so a line made of openers that never close must not cost a rescan of the line each.
/// The inline matchers answer closer lookups from an index built in one pass; this holds them to
/// the scanning matchers they replaced (the reference below, verbatim) and to a time budget.
final class MarkdownSourceHighlighterScanTests: XCTestCase {

    /// The inline pass as it was: each failed opener scans to the end of the line.
    private struct Reference {
        let characters: [Character]
        let utf16Offsets: [Int]
        var spans: [MarkdownSourceSpan] = []

        init(source: String) {
            var characters: [Character] = []
            var offsets: [Int] = []
            var offset = 0
            for character in source {
                characters.append(character)
                offsets.append(offset)
                offset += character.utf16.count
            }
            offsets.append(offset)
            self.characters = characters
            self.utf16Offsets = offsets
        }

        mutating func emit(_ range: Range<Int>, _ style: MarkdownSourceStyle) {
            guard range.lowerBound < range.upperBound, range.upperBound <= characters.count else { return }
            let location = utf16Offsets[range.lowerBound]
            spans.append(
                MarkdownSourceSpan(
                    location: location, length: utf16Offsets[range.upperBound] - location, style: style))
        }

        /// One left-to-right pass with a fixed priority order. Code spans come first because
        /// their contents are literal — `` `**not bold**` `` must stay unstyled inside — and the
        /// pass jumps past whatever it matched, so nothing is styled twice.
        mutating func highlightInline(_ range: Range<Int>) {
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                if let next = matchCodeSpan(at: cursor, limit: range.upperBound)
                    ?? matchWikilink(at: cursor, limit: range.upperBound)
                    ?? matchLink(at: cursor, limit: range.upperBound)
                    ?? matchDelimited(at: cursor, limit: range.upperBound)
                {
                    cursor = next
                } else {
                    cursor += 1
                }
            }
        }

        mutating func matchCodeSpan(at start: Int, limit: Int) -> Int? {
            guard characters[start] == "`" else { return nil }
            var openEnd = start
            while openEnd < limit, characters[openEnd] == "`" { openEnd += 1 }
            let width = openEnd - start
            var cursor = openEnd
            while cursor < limit {
                guard characters[cursor] == "`" else {
                    cursor += 1
                    continue
                }
                var closeEnd = cursor
                while closeEnd < limit, characters[closeEnd] == "`" { closeEnd += 1 }
                if closeEnd - cursor == width {
                    emit(start..<openEnd, .marker)
                    emit(openEnd..<cursor, .inlineCode)
                    emit(cursor..<closeEnd, .marker)
                    return closeEnd
                }
                cursor = closeEnd
            }
            return nil
        }

        mutating func matchWikilink(at start: Int, limit: Int) -> Int? {
            guard start + 1 < limit, characters[start] == "[", characters[start + 1] == "[" else { return nil }
            var cursor = start + 2
            while cursor + 1 < limit {
                if characters[cursor] == "]", characters[cursor + 1] == "]" {
                    emit(start..<(start + 2), .marker)
                    emit((start + 2)..<cursor, .wikilink)
                    emit(cursor..<(cursor + 2), .marker)
                    return cursor + 2
                }
                cursor += 1
            }
            return nil
        }

        mutating func matchLink(at start: Int, limit: Int) -> Int? {
            guard characters[start] == "[" else { return nil }
            guard let closeBracket = find("]", from: start + 1, limit: limit) else { return nil }
            guard closeBracket + 1 < limit, characters[closeBracket + 1] == "(" else { return nil }
            guard let closeParen = find(")", from: closeBracket + 2, limit: limit) else { return nil }
            emit(start..<(start + 1), .marker)
            emit((start + 1)..<closeBracket, .linkText)
            emit(closeBracket..<(closeBracket + 2), .marker)
            emit((closeBracket + 2)..<closeParen, .url)
            emit(closeParen..<(closeParen + 1), .marker)
            return closeParen + 1
        }

        /// `**strong**`, `__strong__`, `*em*`, `_em_`, `~~strike~~`.
        mutating func matchDelimited(at start: Int, limit: Int) -> Int? {
            let character = characters[start]
            guard character == "*" || character == "_" || character == "~" else { return nil }
            var runEnd = start
            while runEnd < limit, characters[runEnd] == character { runEnd += 1 }
            let width = runEnd - start
            let style: MarkdownSourceStyle
            switch (character, width) {
            case ("~", 2): style = .strikethrough
            case ("~", _): return nil
            case (_, 1): style = .emphasis
            case (_, 2): style = .strong
            default: return nil
            }
            // An opener must be followed by content, or `** ` in prose swallows the rest of the
            // line looking for a partner it will not find.
            guard runEnd < limit, characters[runEnd] != " " else { return nil }
            var cursor = runEnd
            while cursor < limit {
                guard characters[cursor] == character else {
                    cursor += 1
                    continue
                }
                var closeEnd = cursor
                while closeEnd < limit, characters[closeEnd] == character { closeEnd += 1 }
                if closeEnd - cursor >= width, characters[cursor - 1] != " " {
                    emit(start..<runEnd, .marker)
                    emit(runEnd..<cursor, style)
                    emit(cursor..<(cursor + width), .marker)
                    return cursor + width
                }
                cursor = closeEnd
            }
            return nil
        }

        func find(_ character: Character, from start: Int, limit: Int) -> Int? {
            var cursor = start
            while cursor < limit {
                if characters[cursor] == character { return cursor }
                cursor += 1
            }
            return nil
        }
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

    // Every opener and closer the inline pass knows, a combining mark that fuses with the
    // character before it, and a space, which decides whether an emphasis run may close.
    private static let pieces = [
        "`", "``", "```", "[", "[[", "]", "]]", "(", ")", "*", "**", "***", "_", "__", "~", "~~", "~~~", " ", "a",
        "\u{301}", "é", "|", "-",
    ]

    /// The first character is `x`, so the line is never a heading, list item, quote, fence,
    /// thematic break or table delimiter and goes straight to the inline pass.
    private static let cases: [String] = {
        var rng = Lcg(state: 20_261_007)
        let random = (0..<60_000).map { _ -> String in
            let length = Int(rng.next() * 18)
            return "x" + (0..<length).map { _ in pieces[Int(rng.next() * Double(pieces.count))] }.joined()
        }
        let exhaustive = allSequences(
            ["`", "``", "[[", "]]", "[", "]", "(", ")", "*", "**", " ", "a", "~~", "_"], length: 5
        )
        .map { "x" + $0 }
        return random + exhaustive
    }()

    func testInlineSpansAreExactlyThoseTheScanningMatchersFound() {
        XCTAssertGreaterThan(Self.cases.count, 500_000, "the case set looks truncated")
        var disagreements: [String] = []
        for source in Self.cases {
            var reference = Reference(source: source)
            reference.highlightInline(0..<reference.characters.count)
            if MarkdownSourceHighlighter.spans(for: source) != reference.spans {
                disagreements.append(source.debugDescription)
                if disagreements.count == 5 { break }
            }
        }
        XCTAssertEqual(disagreements, [])
    }

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

    /// Runs `work` on its own thread and reports whether it finished within `seconds`; a thread
    /// that runs over cannot be cancelled, so a regression fails here and the runaway thread dies
    /// with the test process.
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

    func testCapSizedHostileLinesHighlightInLinearTime() throws {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/notes-link-scaling.json")
        let fixture = try JSONDecoder().decode(ScalingFixture.self, from: Data(contentsOf: path))
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10, "fixture file looks truncated")
        var bodies = fixture.cases.map {
            ($0.name, $0.prefix + String(repeating: $0.unit, count: $0.repeatCount) + $0.suffix)
        }
        // Lines of openers whose closers are missing, rejected or the wrong length.
        let cap = 524_288
        for unit in ["[a](", "[[a#b", "[", "[[", "*a ", "**a ", "_a ", "~~a ", "`a`` ", "(", ")", "]", "]]"] {
            bodies.append(("openers \(unit)", "x" + String(repeating: unit, count: cap / unit.count)))
        }
        // Backtick runs of growing length: no run closes an earlier one.
        var growing = "x"
        var width = 1
        while growing.utf8.count < cap {
            growing += String(repeating: "`", count: width) + "a"
            width += 1
        }
        bodies.append(("growing backtick runs", growing))

        for (name, body) in bodies {
            let started = Date()
            guard finishes(within: 20, { _ = MarkdownSourceHighlighter.spans(for: body) }) else {
                XCTFail("\(name): not highlighted within 20 s")
                return  // the runaway thread is still burning a core; do not start another
            }
            print("scaling \(name): \(Date().timeIntervalSince(started)) s")
        }
    }
}
