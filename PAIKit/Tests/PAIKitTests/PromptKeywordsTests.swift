import Foundation
import Testing

@testable import PAIKit

/// `Resources/prompt-keywords.json` is a byte-identical copy of pai-cloud's
/// `shared/prompt-keywords.json`, the word list and case table the web composer runs too, so a
/// rule or a word that changes on one side and not the other turns one of the two suites red.
@Suite("Prompt keywords")
struct PromptKeywordsTests {
    struct Table: Decodable {
        struct Expected: Decodable, Equatable {
            let word: String
            let start: Int
            let end: Int
        }
        struct KeywordCase: Decodable {
            let `case`: String
            let text: String
            let expect: [Expected]
        }
        let keywords: [String]
        let cases: [KeywordCase]
    }

    static func load() throws -> Table {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/prompt-keywords.json")
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: path))
    }

    @Test("The word list is the shared one")
    func wordList() throws {
        #expect(PromptKeywords.keywords == (try Self.load()).keywords)
    }

    @Test("Every case matches the shared table")
    func cases() throws {
        let table = try Self.load()
        #expect(table.cases.count >= 14, "case table looks truncated")
        for c in table.cases {
            let found = PromptKeywords.find(in: c.text).map {
                Table.Expected(word: $0.word, start: $0.range.location, end: NSMaxRange($0.range))
            }
            #expect(found == c.expect, "\(c.case)")
        }
    }

    @Test("Typing a keyword lists it once and removing the word clears it")
    func typedAndRemoved() {
        #expect(
            PromptKeywords.words(in: "please ultrathink, then ULTRATHINK, then ultracode") == [
                "ultrathink", "ultracode",
            ])
        #expect(PromptKeywords.words(in: "please think").isEmpty)
    }

    @Test("Many spans and keywords stay fast")
    func hostileText() {
        let text = String(repeating: "(a) ultrathink [b] ", count: 20_000)
        let started = Date()
        _ = PromptKeywords.find(in: text)
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
