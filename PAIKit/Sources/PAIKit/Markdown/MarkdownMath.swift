import Foundation

/// LaTeX in a reply, found in the raw text before markdown parses it.
///
/// Markdown has no math syntax, and parsing first would damage the formula: cmark reads `\{` and
/// `\\` as escapes and `*` as emphasis. So each formula is swapped for a token cmark passes through
/// untouched (private-use characters around an index), and the parser turns the token back into a
/// formula where it lands in text, or into the source as written where it lands in code.
///
/// What counts as math:
/// - Display: `$$ … $$` or `\[ … \]` making up whole lines, on one line or across several, outside
///   a fenced code block. A blank line inside ends the search: TeX does not allow one either.
/// - Inline: `$ … $`, `\( … \)` and `$$ … $$` within a line. A `$` opens only before a non-space
///   and closes only after a non-space when no digit follows it, so `$5 and $10` stays text. The
///   first unescaped `$` after an opener decides: when it cannot close, the opener is a price, so
///   `$20 and $30, and $E=mc^2$` keeps both prices and finds one formula. `\$` is an escaped
///   dollar. A backtick code span is skipped whole.
struct MarkdownMath: Sendable {

    enum Kind: Sendable {
        case inline
        case display
    }

    struct Formula: Sendable {
        /// The formula itself, without its delimiters.
        let latex: String
        /// The text as written, delimiters included — what a token restores to inside code.
        let source: String
        let kind: Kind
    }

    private(set) var formulas: [Formula] = []

    static let none = MarkdownMath()

    private static let tokenStart: Character = "\u{E000}"
    private static let tokenEnd: Character = "\u{E001}"

    /// `source` with every formula swapped for its token, and the formulas the tokens name.
    /// Text that already holds the token characters is left alone: its tokens would be ambiguous.
    static func protect(_ source: String) -> (text: String, math: MarkdownMath) {
        guard source.contains("$") || source.contains("\\(") || source.contains("\\["),
            !source.contains(tokenStart)
        else { return (source, .none) }
        var math = MarkdownMath()
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var fence: (character: Character, length: Int)?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                if MarkdownFence.closes(line, character: open.character, length: open.length) { fence = nil }
                output.append(String(line))
                index += 1
                continue
            }
            if let opened = MarkdownFence.opening(line) {
                fence = opened
                output.append(String(line))
                index += 1
                continue
            }
            if let display = displayFormula(lines, at: index) {
                let indent = line.prefix { $0 == " " || $0 == "\t" }
                output.append(indent + math.token(for: display.formula))
                index += display.lineCount
                continue
            }
            output.append(math.protectInline(line))
            index += 1
        }
        guard !math.formulas.isEmpty else { return (source, .none) }
        return (output.joined(separator: "\n"), math)
    }

    // MARK: - Tokens

    private mutating func token(for formula: Formula) -> String {
        formulas.append(formula)
        return "\(Self.tokenStart)\(formulas.count - 1)\(Self.tokenEnd)"
    }

    /// One stretch of parsed text: plain text, or a formula a token stood for.
    enum Piece: Equatable {
        case text(String)
        case formula(Int)
    }

    /// `text` cut at its tokens. A token that names no formula stays text.
    func pieces(of text: String) -> [Piece] {
        guard !formulas.isEmpty, text.contains(Self.tokenStart) else { return [.text(text)] }
        var pieces: [Piece] = []
        var plain = ""
        var rest = Substring(text)
        while let start = rest.firstIndex(of: Self.tokenStart) {
            plain += rest[..<start]
            let afterStart = rest.index(after: start)
            guard let end = rest[afterStart...].firstIndex(of: Self.tokenEnd),
                let number = Int(rest[afterStart..<end]), formulas.indices.contains(number)
            else {
                plain.append(Self.tokenStart)
                rest = rest[afterStart...]
                continue
            }
            if !plain.isEmpty { pieces.append(.text(plain)) }
            plain = ""
            pieces.append(.formula(number))
            rest = rest[rest.index(after: end)...]
        }
        plain += rest
        if !plain.isEmpty { pieces.append(.text(plain)) }
        return pieces
    }

    /// `text` with every token put back as the source it stood for — for code, raw HTML and link
    /// destinations, where a formula is the characters as written.
    func restore(_ text: String) -> String {
        guard !formulas.isEmpty, text.contains(Self.tokenStart) else { return text }
        return pieces(of: text).map { piece in
            switch piece {
            case .text(let text): text
            case .formula(let number): formulas[number].source
            }
        }.joined()
    }

    // MARK: - Display

    private static let displayDelimiters: [(open: String, close: String)] = [("$$", "$$"), ("\\[", "\\]")]

    /// A display formula starting at `lines[index]`, and how many lines it spans.
    private static func displayFormula(_ lines: [Substring], at index: Int) -> (formula: Formula, lineCount: Int)? {
        let first = lines[index].trimmingCharacters(in: .whitespaces)
        for (open, close) in displayDelimiters where first.hasPrefix(open) {
            let rest = first.dropFirst(open.count)
            // On one line: the delimiters close it, and nothing between them closes it earlier.
            if rest.hasSuffix(close) {
                let body = rest.dropLast(close.count)
                guard !body.contains(close) else { return nil }
                let latex = body.trimmingCharacters(in: .whitespaces)
                guard !latex.isEmpty else { return nil }
                return (Formula(latex: latex, source: first, kind: .display), 1)
            }
            guard !rest.contains(close) else { return nil }
            var body = [String(rest)]
            var next = index + 1
            while next < lines.count {
                let line = lines[next].trimmingCharacters(in: .whitespaces)
                if line.isEmpty || MarkdownFence.opening(lines[next]) != nil { return nil }
                if line.hasSuffix(close) {
                    let last = line.dropLast(close.count)
                    guard !last.contains(close) else { return nil }
                    body.append(String(last))
                    let latex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !latex.isEmpty else { return nil }
                    let source = lines[index...next].joined(separator: "\n")
                    return (Formula(latex: latex, source: source, kind: .display), next - index + 1)
                }
                if line.contains(close) { return nil }
                body.append(line)
                next += 1
            }
            return nil
        }
        return nil
    }

    // MARK: - Inline

    private mutating func protectInline(_ line: Substring) -> String {
        guard line.contains("$") || line.contains("\\(") else { return String(line) }
        let characters = Array(line)
        let next = NextIndices(characters)
        var result = ""
        var index = 0

        func formula(_ start: Int, _ contentStart: Int, _ contentEnd: Int, _ end: Int) -> String? {
            let latex = String(characters[contentStart..<contentEnd]).trimmingCharacters(in: .whitespaces)
            guard !latex.isEmpty else { return nil }
            return token(for: Formula(latex: latex, source: String(characters[start..<end]), kind: .inline))
        }

        while index < characters.count {
            let character = characters[index]
            switch character {
            case "\\" where index + 1 < characters.count:
                if characters[index + 1] == "(", let close = next.parenClose(after: index + 2),
                    let token = formula(index, index + 2, close, close + 2)
                {
                    result += token
                    index = close + 2
                } else {
                    result.append(character)
                    result.append(characters[index + 1])
                    index += 2
                }

            case "`":
                let end = next.codeSpanEnd(at: index)
                result += String(characters[index..<end])
                index = end

            case "$" where index + 1 < characters.count && characters[index + 1] == "$":
                if let close = next.doubleDollar(after: index + 2),
                    let token = formula(index, index + 2, close, close + 2)
                {
                    result += token
                    index = close + 2
                } else {
                    result += "$$"
                    index += 2
                }

            case "$":
                if let close = next.closingDollar(opening: index),
                    let token = formula(index, index + 1, close, close + 1)
                {
                    result += token
                    index = close + 1
                } else {
                    result.append(character)
                    index += 1
                }

            default:
                result.append(character)
                index += 1
            }
        }
        return result
    }

    /// For every position of one line, where the next closing delimiter of each kind is, found in
    /// one pass from the right. A line full of unclosed openers then costs one pass, not one scan
    /// to the end of the line per opener.
    private struct NextIndices {
        let characters: [Character]
        private var backtick: [Int?]
        private var doubleDollarStart: [Int?]
        private var parenCloseStart: [Int?]

        init(_ characters: [Character]) {
            self.characters = characters
            let count = characters.count
            backtick = Array(repeating: nil, count: count + 1)
            doubleDollarStart = Array(repeating: nil, count: count + 1)
            parenCloseStart = Array(repeating: nil, count: count + 1)
            var index = count - 1
            while index >= 0 {
                let character = characters[index]
                let following: Character? = index + 1 < count ? characters[index + 1] : nil
                backtick[index] = character == "`" ? index : backtick[index + 1]
                doubleDollarStart[index] =
                    character == "$" && following == "$" ? index : doubleDollarStart[index + 1]
                parenCloseStart[index] =
                    character == "\\" && following == ")" ? index : parenCloseStart[index + 1]
                index -= 1
            }
        }

        /// The `$` closing one opened at `opening`, under the rules that keep a price a price: the
        /// opening one is followed by a non-space, and the first `$` after it — skipping escaped
        /// characters and whole code spans — closes it only when it follows a non-space and no
        /// digit follows it. That `$` failing makes the opener a price.
        func closingDollar(opening: Int) -> Int? {
            let first = opening + 1
            guard first < characters.count, !characters[first].isWhitespace else { return nil }
            var index = first
            while index < characters.count {
                switch characters[index] {
                case "\\": index += 2
                case "`": index = codeSpanEnd(at: index)
                case "$":
                    let following: Character? = index + 1 < characters.count ? characters[index + 1] : nil
                    return !characters[index - 1].isWhitespace && !(following?.isNumber ?? false) ? index : nil
                default: index += 1
                }
            }
            return nil
        }

        func doubleDollar(after start: Int) -> Int? {
            start <= characters.count ? doubleDollarStart[start] : nil
        }

        func parenClose(after start: Int) -> Int? {
            start <= characters.count ? parenCloseStart[start] : nil
        }

        /// Where a code span opened at `start` ends: past the next run of exactly as many
        /// backticks, or past its own run when none closes it.
        func codeSpanEnd(at start: Int) -> Int {
            let length = run(at: start)
            var index = start + length
            while let tick = backtick[index] {
                let closing = run(at: tick)
                if closing == length { return tick + closing }
                index = tick + closing
            }
            return start + length
        }

        private func run(at start: Int) -> Int {
            var end = start
            while end < characters.count, characters[end] == "`" { end += 1 }
            return end - start
        }
    }
}
