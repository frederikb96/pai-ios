import Foundation

/// The fenced-code-block line grammar, for the scans that run over a reply's raw text before
/// markdown parses it (decision markers, math): inside a fence everything is code and stays text.
enum MarkdownFence {

    /// Up to three leading spaces, as markdown allows before a block.
    static func dropIndent(_ line: Substring) -> Substring? {
        let spaces = line.prefix { $0 == " " }.count
        return spaces <= 3 ? line.dropFirst(spaces) : nil
    }

    /// A fence opening: three or more backticks or tildes, anything after.
    static func opening(_ line: Substring) -> (character: Character, length: Int)? {
        guard let rest = dropIndent(line), let first = rest.first, first == "`" || first == "~" else { return nil }
        let length = rest.prefix { $0 == first }.count
        return length >= 3 ? (first, length) : nil
    }

    /// A closing fence: the opening one's character, at least as many, nothing after.
    static func closes(_ line: Substring, character: Character, length: Int) -> Bool {
        guard let rest = dropIndent(line), rest.first == character else { return false }
        let run = rest.prefix { $0 == character }.count
        guard run >= length else { return false }
        return rest.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
    }
}
