import Foundation

/// Claude Code's own slash commands that the composer marks, as opposed to skills (those come from
/// the session's listing, ``SkillMentions``). A built-in runs only as the first token of the text,
/// case-sensitively, and takes everything after the first whitespace as its arguments.
///
/// The web composer (`utils/builtinCommands.ts`) answers the same; the case table in
/// `Resources/builtin-commands.json` binds the two, and a test holds `commands` to that file's list.
public enum BuiltinCommands {
    static let commands = ["compact"]

    /// The built-in command the text starts with, or nil when it does not name one exactly.
    public static func find(in text: String) -> String? {
        let units = Array(text.utf16)
        guard units.first == 0x2F else { return nil }
        for name in commands {
            let nameUnits = Array(name.utf16)
            let end = nameUnits.count + 1
            guard units.count >= end, Array(units[1..<end]) == nameUnits else { continue }
            if units.count == end || isWhitespace(units[end]) { return name }
        }
        return nil
    }

    /// JavaScript's `\s` over one UTF-16 unit — the class the web composer tests against.
    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace || unit == 0xFEFF
    }
}
