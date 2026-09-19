import Foundation

/// What a transcript message *shows*, expressed as data rather than as views.
///
/// Ported from `pai-cloud/web/src/utils/messageDisplay.ts`, and kept deliberately parallel to it:
/// the same descriptors drive rendering and the search index in both clients. An index derived
/// separately from the rendering drifts the moment either side gains a case, and a search that
/// counts a match the screen cannot show sends the reader somewhere with nothing highlighted.
public enum MessageDisplay {

    // MARK: - Previews

    /// How much of a body shows before the reader asks for more.
    ///
    /// Two bounds, not one, and the second is what makes a phone behave. A budget counted in
    /// *source* lines bounds what is laid out but not the height: one source line of prose is
    /// several visual lines at phone width. `visual` is the second bound, applied as a line limit.
    ///
    /// Both are countable before layout — a source slice exactly, a line limit by measuring with
    /// that limit — which is what lets a row's height stay synchronous and exact.
    ///
    /// `slack` exists because a trailer costs a line to draw and a tap to resolve: a body two
    /// lines past its budget is cheaper shown whole than truncated.
    ///
    /// Mirrors `PREVIEW` in `pai-cloud/web/src/utils/messageDisplay.ts`; the two must stay equal
    /// or the same transcript reads as two different densities on the two clients.
    public struct PreviewBudget: Hashable, Sendable {
        /// Source lines shown before truncating; `nil` for a body with no meaningful line
        /// structure to slice by, which is bounded by `visual` alone.
        public let budget: Int?
        /// Extra source lines tolerated rather than truncated. Meaningless without `budget`.
        public let slack: Int
        /// The visual line limit.
        public let visual: Int

        public init(budget: Int? = nil, slack: Int = 0, visual: Int) {
            self.budget = budget
            self.slack = slack
            self.visual = visual
        }
    }

    public enum Preview {
        public static let result = PreviewBudget(budget: 8, slack: 3, visual: 10)
        /// An error is what the reader came for, so it gets roughly double.
        public static let resultError = PreviewBudget(budget: 16, slack: 3, visual: 20)
        public static let diff = PreviewBudget(budget: 12, slack: 4, visual: 14)
        public static let write = PreviewBudget(budget: 5, slack: 2, visual: 7)
        public static let keyValue = PreviewBudget(budget: 4, slack: 2, visual: 6)
        /// Visual-only: these have no meaningful line structure to slice by.
        public static let command = PreviewBudget(visual: 2)
        public static let thinking = PreviewBudget(visual: 2)
        public static let agentPrompt = PreviewBudget(visual: 2)
        public static let report = PreviewBudget(visual: 6)
        public static let noise = PreviewBudget(visual: 2)
    }

    public struct LineSlice: Equatable, Sendable {
        /// The text that reaches the screen.
        public let shown: String
        /// Source lines cut from the end; 0 when the whole body is shown.
        public let hidden: Int
        public let total: Int
    }

    /// Slice a body to its source-line budget.
    ///
    /// Used by the rendering *and* by the check deciding whether a search hit lies past the
    /// preview and therefore needs its row revealed, so the two can never disagree about where a
    /// preview ends. A budget of `nil` shows everything.
    public static func previewLines(_ text: String, _ budget: PreviewBudget) -> LineSlice {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let total = lines.count
        guard let limit = budget.budget, total > limit + budget.slack else {
            return LineSlice(shown: text, hidden: 0, total: total)
        }
        return LineSlice(shown: lines.prefix(limit).joined(separator: "\n"), hidden: total - limit, total: total)
    }

    // MARK: - Tool calls

    /// The shape a tool call's input is rendered in.
    ///
    /// Each case carries the exact strings that reach the screen, prefixes (`- `, `+ `) included —
    /// those are visible text, and a reader can search for them.
    public enum ToolCallSpec: Hashable, Sendable {
        case bash(command: String)
        case inline(text: String)
        case edit(filePath: String, oldString: String?, newString: String?)
        case write(filePath: String, content: String?)
        /// A spawn — the one call whose *identity* is worth more than its arguments.
        case agent(headline: String, description: String?, prompt: String?)
        /// An unmapped call rendered as `key: value` lines.
        case keyValue(lines: [String])
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

        // A spawn is the one call whose *identity* is worth more than its arguments: which agent,
        // of what kind, on which model. The prompt is enormous and the description is the one-line
        // version of it, so both are offered and the renderer's budget decides.
        case "agent", "task":
            let headline = [input.string("name"), input.string("subagent_type"), input.string("model")]
                .compactMap { $0 }
                .joined(separator: " · ")
            return .agent(
                headline: headline.isEmpty ? "agent" : headline,
                description: input.string("description"),
                prompt: input.string("prompt")
            )

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

        case "webfetch":
            if let url = input.string("url") {
                return .inline(text: url)
            }

        case "skill":
            if let skill = input.string("skill") {
                let args = input.string("args")
                return .inline(text: args.map { "/\(skill) \($0)" } ?? "/\(skill)")
            }

        case "taskstop":
            return .inline(text: input.string("task_id") ?? input.string("shell_id") ?? "")

        case "croncreate":
            let parts = [input.string("cron"), input.string("prompt").map { "\"\($0)\"" }].compactMap { $0 }
            return .inline(text: parts.joined(separator: " · "))

        case "crondelete":
            return .inline(text: input.string("id") ?? "")

        // A call whose whole meaning is that it happened — an empty body reads as one line rather
        // than as an empty box.
        case "listagents", "cronlist":
            return .inline(text: "")

        default:
            break
        }

        return .keyValue(lines: keyValueLines(input))
    }

    /// An arbitrary input rendered as `key: value` lines rather than a pretty JSON dump — the
    /// fallback covers every MCP tool and everything Claude Code adds next, so it is the shape most
    /// often on screen for an unmapped call. A nested value stays JSON, compactly, because
    /// inventing a layout for it would be guessing at a shape nobody here knows.
    ///
    /// Sorted by key because a Swift dictionary has no insertion order to preserve — the one place
    /// this cannot match the web's output exactly.
    private static func keyValueLines(_ input: [String: PaiJSONValue]) -> [String] {
        input.keys.sorted().map { key in
            guard let value = input[key] else { return "\(key): " }
            if case .string(let text) = value { return "\(key): \(text)" }
            return "\(key): \(compactJSON(value))"
        }
    }

    /// A home directory the transcript's own machine wrote, shortened the way a shell prompt does.
    ///
    /// The paths in a transcript belong to whatever machine ran the session, never to the device
    /// reading it, so this is a text substitution over the two shapes a Unix home takes rather
    /// than anything resolved from the current process.
    ///
    /// 🚨 A VIEW calls this, never the display model, and the difference is the search index. A
    /// card's model text is what the client index counts occurrences in, while the server matches
    /// the raw stored content — so shortening a path in the model makes the client match text the
    /// store cannot find and miss text it can, which reaches the reader as a row highlighted while
    /// the counter reads zero. The header is the one place this is drawn and the header is outside
    /// the index, so shortening it there costs nothing.
    public static func abbreviatingHome(_ path: String) -> String {
        for root in ["/home/", "/Users/"] where path.hasPrefix(root) {
            let rest = path.dropFirst(root.count)
            guard let slash = rest.firstIndex(of: "/") else { return "~" }
            return "~" + rest[slash...]
        }
        return path
    }

    /// The file a call acts on, drawn above its body instead of as the body's first line.
    ///
    /// A path is the one part of an edit or a write that is worth reading whatever else the row is
    /// showing, and it is exactly the part a sideways-scrolling diff hides: the box starts at
    /// column zero of a line that is usually longer than a phone. So it leaves the body entirely
    /// and becomes the card's own header, which wraps and is never clipped.
    public static func headerPath(of spec: ToolCallSpec) -> String? {
        switch spec {
        case .edit(let filePath, _, _): return filePath
        case .write(let filePath, _): return filePath
        default: return nil
        }
    }

    /// Every string a ``ToolCallSpec`` puts on screen *in its body*, in render order — a path that
    /// ``headerPath(of:)`` lifts out is not part of this.
    public static func displayText(of spec: ToolCallSpec) -> String {
        switch spec {
        case .bash(let command):
            return command
        case .inline(let text):
            return text
        case .edit(_, let oldString, let newString):
            guard oldString != nil || newString != nil else { return "" }
            let diffLines = EditDiff.lines(old: oldString ?? "", new: newString ?? "")
            return diffLines.map { line -> String in
                switch line {
                case .context(let text): return text
                case .removed(let text): return "- \(text)"
                case .added(let text): return "+ \(text)"
                }
            }.joined(separator: "\n")
        case .write(_, let content):
            return content ?? ""
        case .agent(let headline, let description, let prompt):
            return [headline, description, prompt].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: "\n")
        case .keyValue(let lines):
            return lines.joined(separator: "\n")
        }
    }

    /// The bold word a row leads with.
    ///
    /// A *successful* result has none: its glyph and its place under the call are the label, the
    /// way the terminal's own output marker works. Naming the tool again was both redundant and a
    /// whole extra line per result — and a result is nearly always directly beneath its call
    /// (measured over a real session: 30 of 37 adjacent, 7 two rows apart with a thought between).
    ///
    /// A *failed* one says so, because that is the row a reader scrolling back is looking for and
    /// the one place naming the tool earns its space.
    public static func toolCardLabel(call: ToolCall?, result: ToolResult?) -> String {
        formatToolName(call?.name ?? result?.toolName ?? "Unknown")
    }

    /// A tool result's body as rendered.
    ///
    /// ANSI is stripped rather than drawn as colour, from every tool and not only from Bash. Two
    /// reasons, and the second is the one that bites: colour in the transcript means *state* — a
    /// failed row is the only red thing on screen — so output that paints itself would compete
    /// with the one signal worth finding while scrolling. And a preview slices this string, which
    /// cannot be done safely on text carrying escapes: a cut landing mid-sequence leaks the
    /// escape onto the screen as literal characters.
    public static func toolResultDisplayText(_ result: ToolResult, toolName: String? = nil) -> String {
        guard !result.content.isEmpty else { return "" }
        let displayed = toolName?.lowercased() == "read" ? stripLineNumbers(result.content) : result.content
        return Ansi.hasEscapes(displayed) ? Ansi.strip(displayed) : displayed
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
        case "command_output": return "Output"
        case "image": return "Image"
        case "compact": return "Compacted"
        case "compact_summary": return "Compaction summary"
        case "hook": return "Hooks"
        case "duration": return "Duration"
        case "interrupt": return "Interrupted"
        case "notification": return "Task notification"
        case "scheduled": return "Scheduled"
        case "pai_message": return "Relayed message"
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

    /// What a `subtype=command` row shows, whichever shape it was ingested in.
    ///
    /// Rows parsed since the fix carry the clean `"{name}\n\n{args}"` shape; older ones still
    /// carry Claude Code's raw `<command-name>`/`<command-args>` wrapper, permanently, because
    /// nothing re-parses an already-ingested message. The old transcript hid that difference by
    /// collapsing the body behind a chevron — this design shows every body by default, so the
    /// wrapper has to be understood rather than merely not-clicked.
    ///
    /// One function so the rendering and the search index cannot disagree about which text a
    /// legacy row puts on screen.
    public static func commandParts(_ content: String) -> (name: String, args: String) {
        guard isUnparsedCommandXml(content) else {
            let split = splitLabeledContent(content)
            return (split.label, split.body)
        }
        // A wrapper this does not recognise still must not put its tags on screen; an empty name
        // renders as the bare label, which is what the row degrades to.
        return (
            taggedValue("command-name", in: content) ?? "",
            taggedValue("command-args", in: content) ?? ""
        )
    }

    private static func taggedValue(_ tag: String, in content: String) -> String? {
        guard let open = content.range(of: "<\(tag)>"),
            let close = content.range(of: "</\(tag)>", range: open.upperBound..<content.endIndex)
        else { return nil }
        return String(content[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// One non-string tool-input value, on one line beside its key.
    ///
    /// `withoutEscapingSlashes` is not cosmetic: tool inputs are mostly file paths, and Foundation
    /// escapes `/` by default, so every path would read as `\/Users\/…`.
    private static func compactJSON(_ value: PaiJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
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
