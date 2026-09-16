import Foundation

/// What a transcript message *shows*, expressed as data rather than as views.
///
/// Ported from `pai-cloud/web/src/utils/messageDisplay.ts`, and kept deliberately parallel to it:
/// the same descriptors drive rendering and the search index in both clients. An index derived
/// separately from the rendering drifts the moment either side gains a case, and a search that
/// counts a match the screen cannot show sends the reader somewhere with nothing highlighted.
public enum MessageDisplay {

    // MARK: - Tool calls

    /// The shape a tool call's input is rendered in.
    ///
    /// Each case carries the exact strings that reach the screen, prefixes (`$ `, `- `, `+ `)
    /// included — those are visible text, and a reader can search for them.
    public enum ToolCallSpec: Hashable, Sendable {
        case bash(command: String)
        case inline(text: String)
        case edit(filePath: String, oldString: String?, newString: String?)
        case write(filePath: String, content: String?)
        case json(text: String)
    }

    public static func spec(for call: ToolCall) -> ToolCallSpec {
        let name = call.name.lowercased()
        let input = call.input

        switch name {
        case "bash":
            if let command = input.string("command") {
                return .bash(command: command)
            }

        case "read":
            if let path = input.string("file_path") {
                var parts = [path]
                if let offset = input.number("offset") { parts.append("from line \(integer(offset))") }
                if let limit = input.number("limit") { parts.append("\(integer(limit)) lines") }
                return .inline(text: parts.joined(separator: " "))
            }

        case "edit", "multiedit":
            if let path = input.string("file_path") {
                return .edit(
                    filePath: path,
                    oldString: input.string("old_string"),
                    newString: input.string("new_string")
                )
            }

        case "write":
            if let path = input.string("file_path") {
                return .write(filePath: path, content: input.string("content"))
            }

        case "grep":
            var parts: [String] = []
            if let pattern = input.string("pattern") { parts.append("/\(pattern)/") }
            if let path = input.string("path") { parts.append("in \(path)") }
            if let glob = input.string("glob") { parts.append("(\(glob))") }
            return .inline(text: parts.joined(separator: " "))

        case "glob":
            var parts: [String] = []
            if let pattern = input.string("pattern") { parts.append(pattern) }
            if let path = input.string("path") { parts.append("in \(path)") }
            return .inline(text: parts.joined(separator: " "))

        case "websearch":
            if let query = input.string("query") {
                return .inline(text: "\"\(query)\"")
            }

        case "skill":
            if let skill = input.string("skill") {
                return .inline(text: "/\(skill)")
            }

        default:
            break
        }

        return .json(text: prettyJSON(input))
    }

    /// Every string a ``ToolCallSpec`` puts on screen, in render order.
    public static func displayText(of spec: ToolCallSpec) -> String {
        switch spec {
        case .bash(let command):
            return "$ \(command)"
        case .inline(let text):
            return text
        case .edit(let filePath, let oldString, let newString):
            guard oldString != nil || newString != nil else { return filePath }
            let diffLines = EditDiff.lines(old: oldString ?? "", new: newString ?? "")
            let rendered = diffLines.map { line -> String in
                switch line {
                case .context(let text): return text
                case .removed(let text): return "- \(text)"
                case .added(let text): return "+ \(text)"
                }
            }
            return ([filePath] + rendered).joined(separator: "\n")
        case .write(let filePath, let content):
            return [filePath, content].compactMap { $0 }.joined(separator: "\n")
        case .json(let text):
            return text
        }
    }

    /// The header line of a tool card.
    public static func toolCardLabel(call: ToolCall?, result: ToolResult?) -> String {
        let name = call?.name ?? result?.toolName ?? "Unknown"
        let isOrphanedResult = result != nil && call == nil
        return formatToolName(name) + (isOrphanedResult ? " Result" : "")
    }

    /// A tool result's body as rendered.
    ///
    /// ANSI-coloured bash output is drawn as styled text, so its escape sequences are never
    /// characters on screen — and therefore never characters search can match.
    public static func toolResultDisplayText(_ result: ToolResult, toolName: String? = nil) -> String {
        guard !result.content.isEmpty else { return "" }
        let name = toolName?.lowercased()
        let displayed = name == "read" ? stripLineNumbers(result.content) : result.content
        return name == "bash" && Ansi.hasEscapes(displayed) ? Ansi.strip(displayed) : displayed
    }

    public struct NotifyReply: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    /// Best-effort extraction of a `notify` tool call's title/body from its own reply text, for
    /// rendering the notification's title and body directly instead of the reply's raw YAML —
    /// not a general YAML parser.
    ///
    /// `notify()` (`backend/src/pai_cloud/mcp_server.py`) always emits `title` and `body` as the
    /// two lines right after `marker`, via block-style YAML (`backend/src/pai_cloud/mcp_serializer.py`,
    /// PyYAML's `SafeDumper` with `default_flow_style=False`). PyYAML renders a value as a bare
    /// `key: value` plain scalar whenever it can, and switches to single-quoted (doubling any
    /// embedded `'`) or double-quoted (backslash escapes) the moment it can't: a newline,
    /// leading/trailing whitespace, a leading digit or "yes"/"no"/"null"-shaped ambiguity, an
    /// inline `: `, or a character double-quoting alone can represent. A value long enough to
    /// cross PyYAML's output width also folds onto indented continuation lines — this rejoins
    /// those with a single space, YAML's own rule for a lone line break.
    ///
    /// Returns `nil` for anything this cannot reconstruct losslessly: an unterminated quote, an
    /// escape neither quoted style defines, or two or more consecutive line breaks inside a
    /// quoted value — YAML folds those to a literal embedded newline rather than a space, which
    /// this deliberately does not attempt to reverse: doing so correctly means re-implementing
    /// YAML's folding rules for a cosmetic gain. The caller falls back to the raw dump in that
    /// case. Mirrors the web's `parseNotifyReply` (`web/src/utils/messageDisplay.ts`) exactly, so
    /// the two clients agree on when to special-case a reply.
    public static func parseNotifyReply(_ content: String) -> NotifyReply? {
        guard let title = scalarValue(forKey: "title", in: content),
            let body = scalarValue(forKey: "body", in: content)
        else { return nil }
        return NotifyReply(title: title, body: body)
    }

    private static func scalarValue(forKey key: String, in content: String) -> String? {
        guard
            let regex = try? NSRegularExpression(
                pattern: "^\(NSRegularExpression.escapedPattern(for: key)): (.*)$", options: [.anchorsMatchLines])
        else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range), match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: content)
        else { return nil }

        guard valueRange.lowerBound < valueRange.upperBound else { return "" }
        switch content[valueRange.lowerBound] {
        case "'":
            return parseSingleQuotedScalar(in: content, from: content.index(after: valueRange.lowerBound))
        case "\"":
            return parseDoubleQuotedScalar(in: content, from: content.index(after: valueRange.lowerBound))
        default:
            return parsePlainScalar(in: content, firstLine: content[valueRange], from: valueRange.upperBound)
        }
    }

    /// A plain scalar's first line, plus any indented continuation lines PyYAML wrapped it onto
    /// — each rejoined with a single space. A continuation is recognised only by its leading
    /// whitespace, which is what tells it apart from the next `key: value` line at column 0.
    private static func parsePlainScalar(in content: String, firstLine: Substring, from lineEnd: String.Index)
        -> String
    {
        var result = String(firstLine)
        var index = lineEnd
        while index < content.endIndex, content[index] == "\n" {
            let afterBreak = content.index(after: index)
            guard afterBreak < content.endIndex, content[afterBreak] == " " || content[afterBreak] == "\t" else {
                break
            }
            var cursor = afterBreak
            while cursor < content.endIndex, content[cursor] == " " || content[cursor] == "\t" {
                cursor = content.index(after: cursor)
            }
            let lineStart = cursor
            while cursor < content.endIndex, content[cursor] != "\n" {
                cursor = content.index(after: cursor)
            }
            result += " " + content[lineStart..<cursor]
            index = cursor
        }
        return result
    }

    /// A single-quoted scalar's content, from just past the opening `'`. `''` is an escaped
    /// literal quote; any other `'` closes the value. A lone line break (PyYAML's own width
    /// wrap) folds to a single space; two or more in a row would be a literal embedded newline —
    /// unsupported, see ``parseNotifyReply(_:)``.
    private static func parseSingleQuotedScalar(in content: String, from start: String.Index) -> String? {
        var result = ""
        var index = start
        while index < content.endIndex {
            switch content[index] {
            case "'":
                let next = content.index(after: index)
                if next < content.endIndex, content[next] == "'" {
                    result.append("'")
                    index = content.index(after: next)
                } else {
                    return result
                }
            case "\n":
                guard let cursor = foldLineBreak(in: content, from: index) else { return nil }
                result.append(" ")
                index = cursor
            default:
                result.append(content[index])
                index = content.index(after: index)
            }
        }
        return nil
    }

    /// A double-quoted scalar's content, from just past the opening `"`. Handles the escapes
    /// PyYAML's emitter can produce — including a `\` immediately before a line break, which
    /// marks a width-wrap fold PyYAML itself makes explicit rather than implicit: the break and
    /// its continuation-line indent are dropped outright, with no space inserted (a folded space
    /// in this style is written back out as its own `\ ` escape). An unescaped line break follows
    /// the same fold-or-bail rule as the single-quoted case.
    private static func parseDoubleQuotedScalar(in content: String, from start: String.Index) -> String? {
        var result = ""
        var index = start
        while index < content.endIndex {
            let ch = content[index]
            if ch == "\"" {
                return result
            } else if ch == "\\" {
                let escapeStart = content.index(after: index)
                guard escapeStart < content.endIndex else { return nil }
                let escapeChar = content[escapeStart]
                if escapeChar == "\n" {
                    var cursor = content.index(after: escapeStart)
                    while cursor < content.endIndex, content[cursor] == " " || content[cursor] == "\t" {
                        cursor = content.index(after: cursor)
                    }
                    index = cursor
                } else if let mapped = Self.doubleQuoteEscapes[escapeChar] {
                    result.append(mapped)
                    index = content.index(after: escapeStart)
                } else if let hexLength = Self.doubleQuoteHexEscapeLengths[escapeChar] {
                    guard
                        let scalar = readHexEscape(
                            in: content, from: content.index(after: escapeStart), length: hexLength)
                    else { return nil }
                    result.append(scalar.value)
                    index = scalar.end
                } else {
                    return nil
                }
            } else if ch == "\n" {
                guard let cursor = foldLineBreak(in: content, from: index) else { return nil }
                result.append(" ")
                index = cursor
            } else {
                result.append(ch)
                index = content.index(after: index)
            }
        }
        return nil
    }

    /// Consumes one lone line break plus the following line's leading indentation — PyYAML's
    /// width-wrap fold. Returns `nil` (unsupported: a literal embedded newline) if a second break
    /// immediately follows, rather than indented content.
    private static func foldLineBreak(in content: String, from index: String.Index) -> String.Index? {
        var cursor = content.index(after: index)
        guard cursor >= content.endIndex || content[cursor] != "\n" else { return nil }
        while cursor < content.endIndex, content[cursor] == " " || content[cursor] == "\t" {
            cursor = content.index(after: cursor)
        }
        return cursor
    }

    private static func readHexEscape(in content: String, from start: String.Index, length: Int)
        -> (value: Character, end: String.Index)?
    {
        var cursor = start
        var hex = ""
        for _ in 0..<length {
            guard cursor < content.endIndex, content[cursor].isHexDigit else { return nil }
            hex.append(content[cursor])
            cursor = content.index(after: cursor)
        }
        guard let code = UInt32(hex, radix: 16), let unicodeScalar = Unicode.Scalar(code) else { return nil }
        return (Character(unicodeScalar), cursor)
    }

    /// PyYAML's double-quoted single-character escapes (`yaml/scanner.py`'s `ESCAPE_REPLACEMENTS`).
    private static let doubleQuoteEscapes: [Character: Character] = [
        "0": "\0", "a": "\u{07}", "b": "\u{08}", "t": "\t", "n": "\n", "v": "\u{0B}",
        "f": "\u{0C}", "r": "\r", "e": "\u{1B}", " ": " ", "\"": "\"", "\\": "\\",
        "/": "/", "N": "\u{85}", "_": "\u{A0}", "L": "\u{2028}", "P": "\u{2029}",
    ]

    /// PyYAML's `\xXX` / `\uXXXX` / `\UXXXXXXXX` hex escapes, keyed by their digit count.
    private static let doubleQuoteHexEscapeLengths: [Character: Int] = ["x": 2, "u": 4, "U": 8]

    /// Strips the line-number prefixes the Read tool emits (`   141→content`).
    ///
    /// Written as a scan rather than a regex: this runs over every Read result in a transcript,
    /// and those are routinely the largest payloads in it.
    public static func stripLineNumbers(_ content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                var cursor = line.startIndex
                while cursor < line.endIndex, line[cursor] == " " || line[cursor] == "\t" {
                    cursor = line.index(after: cursor)
                }
                let digitsStart = cursor
                while cursor < line.endIndex, line[cursor].isASCII, line[cursor].isNumber {
                    cursor = line.index(after: cursor)
                }
                guard cursor > digitsStart, cursor < line.endIndex, line[cursor] == "→" else { return line }
                return line[line.index(after: cursor)...]
            }
            .joined(separator: "\n")
    }

    // MARK: - System messages

    public static func systemLabel(subtype: String?, content: String?) -> String {
        switch subtype {
        case "skill": return "Skill"
        case "context": return "Context"
        case "command": return "Command"
        case "command_output": return "Command Output"
        case "image": return "Image"
        case "compact": return "Compacted"
        case "compact_summary": return "Compact Summary"
        case "hook": return "Hook"
        case "duration": return "Duration"
        case "interrupt": return "Interrupted"
        case "notification": return "Notification"
        default:
            // An empty string is falsy in the original and must fall through to "System" here
            // too, or an empty-content row gets a blank label instead of one.
            guard let content, !content.isEmpty else { return "System" }
            return String(content.prefix(60))
        }
    }

    /// Splits content stored as `"{label}\n\n{body}"`.
    ///
    /// Shared by an agent message (`"{sender}\n\n{report}"`) and a command invocation
    /// (`"{name}\n\n{args}"`) for the same reason: the label is the message's identity, the body
    /// is what it has to say.
    public static func splitLabeledContent(_ content: String) -> (label: String, body: String) {
        guard let separator = content.range(of: "\n\n") else { return (content, "") }
        return (String(content[content.startIndex..<separator.lowerBound]), String(content[separator.upperBound...]))
    }

    /// A `subtype=command` row whose content is still the raw `<command-name>` wrapper rather
    /// than the `"{name}\n\n{args}"` shape the parser now produces.
    ///
    /// Only transcripts ingested before that fix can be this shape, but those rows are permanent
    /// — nothing re-parses a stored message. A caller must route this to a plain-text fallback,
    /// or the wrapper tags become the card's visible label.
    public static func isUnparsedCommandXml(_ content: String) -> Bool {
        content.hasPrefix("<")
    }

    /// A plain user message whose content is actually a raw `<local-command-…>` wrapper, from a
    /// window where the parser did not classify that tag. Permanent for whatever landed then, so
    /// a caller must reroute it rather than draw it as Freddy's own bubble.
    ///
    /// Matched by scanning rather than by regex: the original's pattern closes on a backreference
    /// to its own opening tag, and expressing that faithfully matters more than expressing it
    /// briefly — a mismatched pair must not be treated as a match.
    public static func legacyLocalCommandTag(_ content: String) -> (kind: String, inner: String)? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let opening = "<local-command-"
        guard trimmed.hasPrefix(opening) else { return nil }

        let afterOpening = trimmed.index(trimmed.startIndex, offsetBy: opening.count)
        guard let kindEnd = trimmed[afterOpening...].firstIndex(of: ">") else { return nil }

        let kind = String(trimmed[afterOpening..<kindEnd])
        guard !kind.isEmpty, kind.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else {
            return nil
        }

        let closing = "</local-command-\(kind)>"
        guard trimmed.hasSuffix(closing) else { return nil }

        let bodyStart = trimmed.index(after: kindEnd)
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -closing.count)
        guard bodyStart <= bodyEnd else { return nil }

        return (kind, String(trimmed[bodyStart..<bodyEnd]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Helpers

    /// `mcp__server__tool` reads as `server: tool`; everything else is left alone.
    public static func formatToolName(_ name: String) -> String {
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst("mcp__".count).components(separatedBy: "__")
        guard parts.count >= 2 else { return name }
        return "\(parts[0]): \(parts.dropFirst().joined(separator: "."))"
    }

    /// JSON numbers arrive as `Double`, so interpolating one directly would print "line 141.0".
    ///
    /// The range check is not theoretical politeness: `Int(Double)` traps rather than overflows,
    /// and this value comes from a transcript, so an absurd number would take down the renderer
    /// on a message rather than merely display oddly.
    private static func integer(_ value: Double) -> String {
        guard value == value.rounded(), value.magnitude < Double(Int.max) else {
            return String(value)
        }
        return String(Int(value))
    }

    /// Pretty-prints a tool input the way the tool card shows it.
    ///
    /// `withoutEscapingSlashes` is not cosmetic: tool inputs are mostly file paths, and Foundation
    /// escapes `/` by default, so every path would read as `\/Users\/…`. Keys are sorted because a
    /// Swift dictionary has no insertion order to preserve — the one place this cannot match the
    /// web's output exactly.
    private static func prettyJSON(_ input: [String: PaiJSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input), let text = String(data: data, encoding: .utf8) else {
            return ""
        }
        return text
    }
}

extension [String: PaiJSONValue] {
    fileprivate func string(_ key: String) -> String? {
        if case .string(let value) = self[key] { return value }
        return nil
    }

    fileprivate func number(_ key: String) -> Double? {
        // `PaiJSONValue.number` carries `Decimal` (see its doc comment), not `Double` — converted
        // here at the one call site that wants display precision, not exactness.
        if case .number(let value) = self[key] { return Double(truncating: NSDecimalNumber(decimal: value)) }
        return nil
    }
}
