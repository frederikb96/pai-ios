import Foundation
import Testing

@testable import PAIKit

/// `Resources/skill-mention-cases.json` is a byte-identical copy of pai-cloud's
/// `shared/skill-mention-cases.json`, the case table the web composer runs too, so a rule that
/// changes on one side and not the other turns one of the two suites red.
@Suite("Skill mentions")
struct SkillMentionsTests {
    struct Cases: Decodable {
        struct Expected: Decodable {
            let kind: String
            let token: String
            let name: String
            let start: Int?
            let end: Int?
        }
        struct MentionCase: Decodable {
            let `case`: String
            let text: String
            let expect: [Expected]
        }
        struct CompletionExpected: Decodable, Equatable {
            let start: Int
            let end: Int
            let candidates: [String]
        }
        struct CompletionCase: Decodable {
            let `case`: String
            let text: String
            let caret: Int
            let expect: CompletionExpected?
        }
        struct ReplacementExpected: Decodable {
            let text: String
            let caret: Int
        }
        struct ReplacementCase: Decodable {
            let `case`: String
            let text: String
            let start: Int
            let end: Int
            let name: String
            let expect: ReplacementExpected
        }
        let names: [String]
        let mentions: [MentionCase]
        let completions: [CompletionCase]
        let replacements: [ReplacementCase]
    }

    static func load() throws -> Cases {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/skill-mention-cases.json")
        return try JSONDecoder().decode(Cases.self, from: Data(contentsOf: path))
    }

    @Test("Every mention case matches the shared table")
    func mentions() throws {
        let cases = try Self.load()
        #expect(cases.mentions.count >= 15, "case table looks truncated")
        for c in cases.mentions {
            let found = SkillMentions.find(in: c.text, names: cases.names)
            #expect(
                found.map { "\($0.kind.rawValue) \($0.token) \($0.name)" }
                    == c.expect.map { "\($0.kind) \($0.token) \($0.name)" }, "\(c.case)")
            for (expected, mention) in zip(c.expect, found) {
                #expect((c.text as NSString).substring(with: mention.range) == "/" + expected.token, "\(c.case)")
                if let start = expected.start, let end = expected.end {
                    #expect(mention.range == NSRange(location: start, length: end - start), "\(c.case)")
                }
            }
        }
    }

    @Test("Every completion case matches the shared table")
    func completions() throws {
        let cases = try Self.load()
        #expect(cases.completions.count >= 8, "case table looks truncated")
        for c in cases.completions {
            let found = SkillMentions.completion(in: c.text, caret: c.caret, names: cases.names).map {
                Cases.CompletionExpected(
                    start: $0.range.location, end: NSMaxRange($0.range), candidates: $0.candidates)
            }
            #expect(found == c.expect, "\(c.case)")
        }
    }

    @Test("Every replacement case matches the shared table")
    func replacements() throws {
        let cases = try Self.load()
        for c in cases.replacements {
            let placed = SkillMentions.replace(
                NSRange(location: c.start, length: c.end - c.start), in: c.text, with: c.name)
            #expect(placed.text == c.expect.text, "\(c.case)")
            #expect(placed.caret == c.expect.caret, "\(c.case)")
        }
    }

    @Test("A pasted wall of unknown slash words stays fast")
    func hostileText() {
        let text = (0..<20_000).map { "/word\($0)" }.joined(separator: " ")
        let names = (0..<200).map { "skill-name-\($0)" }
        let started = Date()
        _ = SkillMentions.find(in: text, names: names)
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
