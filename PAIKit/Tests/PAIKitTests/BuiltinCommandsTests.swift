import Foundation
import Testing

@testable import PAIKit

/// `Resources/builtin-commands.json` is a byte-identical copy of pai-cloud's
/// `shared/builtin-commands.json`, the command list and case table the web composer runs too, so a
/// rule or a command that changes on one side and not the other turns one of the two suites red.
@Suite("Builtin commands")
struct BuiltinCommandsTests {
    struct Table: Decodable {
        struct CommandCase: Decodable {
            let `case`: String
            let text: String
            let expect: String?
        }
        let commands: [String]
        let cases: [CommandCase]
    }

    static func load() throws -> Table {
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Resources/builtin-commands.json")
        return try JSONDecoder().decode(Table.self, from: Data(contentsOf: path))
    }

    @Test("The command list is the shared one")
    func commandList() throws {
        #expect(BuiltinCommands.commands == (try Self.load()).commands)
    }

    @Test("Every case matches the shared table")
    func cases() throws {
        let table = try Self.load()
        #expect(table.cases.count >= 10, "case table looks truncated")
        for c in table.cases {
            #expect(BuiltinCommands.find(in: c.text) == c.expect, "\(c.case)")
        }
    }

    @Test("The composer row shows the chip for a draft starting with the command")
    func composerRow() {
        #expect(SkillComposer.builtinCommand(text: "/compact keep the plan", liveTake: false) == "compact")
        #expect(SkillComposer.builtinCommand(text: "/compact", liveTake: true) == nil)
        #expect(SkillComposer.builtinCommand(text: "hello", liveTake: false) == nil)
    }
}
