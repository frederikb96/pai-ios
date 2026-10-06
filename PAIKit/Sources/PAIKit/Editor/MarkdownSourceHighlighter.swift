import Foundation

/// How one stretch of markdown *source* should look while it is being edited.
///
/// Source highlighting, not live preview: the markup stays on screen and is styled, rather than
/// being hidden and replaced by what it produces. A heading's `#` is dimmed and still there; the
/// asterisks around bold text are dimmed and still there. That is what the web editor does and
/// what Obsidian's source mode does, and it is the whole reason this is tractable — a live
/// preview would need the text to reflow as the caret moves.
public enum MarkdownSourceStyle: Equatable, Sendable, Hashable {
    /// Setext and ATX headings alike, 1–6.
    case heading(level: Int)
    /// Markup punctuation — `#`, `*`, backticks, `>`, brackets. Dimmed rather than hidden.
    case marker
    case strong
    case emphasis
    case strikethrough
    case inlineCode
    /// The inside of a fenced block. Its fences are ``marker``.
    case codeBlockContent
    case linkText
    case url
    /// A `[[wikilink]]`'s target, which is a tappable link to another note.
    case wikilink
    case quote
    case listMarker
    case thematicBreak
    /// The YAML block at the top of a note. Freddy's own vault metadata — styled as a unit and
    /// never parsed, since anything that parsed it could rewrite it.
    case frontmatter
}

/// One styled range, in UTF-16 offsets.
///
/// UTF-16 because that is what `NSRange` and every text view on this platform speak. Choosing it
/// here rather than at the boundary avoids the trap that catches ports of this: a parser that
/// reports UTF-8 columns or `String.Index` offsets agrees with UTF-16 on ASCII and diverges the
/// moment a note contains an emoji or an umlaut, which is a highlighting bug that appears only in
/// real notes and never in a test written in English.
public struct MarkdownSourceSpan: Equatable, Sendable, Hashable {
    public let location: Int
    public let length: Int
    public let style: MarkdownSourceStyle

    public init(location: Int, length: Int, style: MarkdownSourceStyle) {
        self.location = location
        self.length = length
        self.style = style
    }

    public var end: Int { location + length }
}

/// Scans markdown source and says how to paint it.
///
/// Its own scanner rather than swift-markdown, for a reason that is easy to miss: cmark is a
/// *rendering* parser. It hands back a heading and its text, and throws the `#` away — but the
/// dimmed `#` is precisely what the Obsidian look is made of. An editor needs a parser that
/// keeps every marker as a token, which is what the web gets from Lezer and what this provides.
///
/// Deliberately a single left-to-right pass with a fixed priority order rather than a full
/// CommonMark implementation. Highlighting that is slightly wrong on a pathological nesting is
/// invisible; highlighting that is slow on every keystroke is not.
public enum MarkdownSourceHighlighter {

    public static func spans(for source: String) -> [MarkdownSourceSpan] {
        guard !source.isEmpty else { return [] }
        var scanner = Scanner(source: source)
        scanner.run()
        return scanner.spans
    }

    private struct Scanner {
        let characters: [Character]
        /// UTF-16 offset of each character, plus a final entry for the end. Precomputed so
        /// emitting a span is arithmetic rather than an index conversion per span.
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

        mutating func run() {
            let lines = lineRanges()
            var index = 0

            // Frontmatter first and only at the very top: a `---` anywhere else is a thematic
            // break, and treating a mid-document one as frontmatter would grey out the rest of
            // the note.
            if let end = frontmatterEnd(lines: lines) {
                emit(lines[0].lowerBound..<lines[end].upperBound, .frontmatter)
                index = end + 1
            }

            var openFence: String?
            while index < lines.count {
                let line = lines[index]
                index += 1

                if let fence = openFence {
                    let closes = MarkdownLineSyntax.closesFence(text(of: line), opener: fence)
                    emit(line, closes ? .marker : .codeBlockContent)
                    if closes { openFence = nil }
                    continue
                }
                if let fence = MarkdownLineSyntax.openingFence(in: text(of: line)) {
                    emit(line, .marker)
                    openFence = fence
                    continue
                }

                highlightLine(line)
            }
        }

        // MARK: Lines

        /// `isNewline` rather than `== "\n"` — see ``MarkdownLineSyntax/splitKeepingTerminators(_:)``,
        /// the other independent scanner that made the same mistake. Swift clusters a `\r\n` pair
        /// into one `Character`, equal to neither bare terminator, so comparing against the
        /// literal leaves a CRLF-terminated note as one unbroken line here too.
        func lineRanges() -> [Range<Int>] {
            var ranges: [Range<Int>] = []
            var start = 0
            for index in characters.indices where characters[index].isNewline {
                ranges.append(start..<(index + 1))
                start = index + 1
            }
            if start < characters.count { ranges.append(start..<characters.count) }
            return ranges
        }

        func text(of range: Range<Int>) -> String {
            String(characters[range])
        }

        /// The index of the closing `---` line, when the document opens with frontmatter.
        func frontmatterEnd(lines: [Range<Int>]) -> Int? {
            guard let first = lines.first, text(of: first).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
            else { return nil }
            for index in 1..<lines.count
            where text(of: lines[index]).trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
                return index
            }
            // An unterminated block is not frontmatter — it is a thematic break followed by text,
            // and dimming the whole note on a stray `---` at the top would be spectacular.
            return nil
        }

        // MARK: One line

        mutating func highlightLine(_ line: Range<Int>) {
            var content = trimmedTrailingNewline(line)
            guard content.lowerBound < content.upperBound else { return }

            let raw = text(of: content)
            let leading = raw.prefix { $0 == " " }.count
            let body = content.lowerBound + leading

            if raw.trimmingCharacters(in: .whitespaces).isEmpty { return }

            if isThematicBreak(raw) {
                emit(content, .thematicBreak)
                return
            }

            // Blockquote markers, possibly several. The rest of the line is still styled — a
            // quoted heading is a heading.
            var cursor = body
            var quoted = false
            while cursor < content.upperBound, characters[cursor] == ">" {
                quoted = true
                var markerEnd = cursor + 1
                if markerEnd < content.upperBound, characters[markerEnd] == " " { markerEnd += 1 }
                emit(cursor..<markerEnd, .marker)
                cursor = markerEnd
                while cursor < content.upperBound, characters[cursor] == " " { cursor += 1 }
            }
            if quoted {
                emit(cursor..<content.upperBound, .quote)
                content = cursor..<content.upperBound
            }

            if let heading = atxHeading(in: content) {
                emit(content.lowerBound..<heading.contentStart, .marker)
                emit(heading.contentStart..<content.upperBound, .heading(level: heading.level))
                highlightInline(heading.contentStart..<content.upperBound)
                return
            }

            if let marker = listMarker(in: content) {
                emit(marker, .listMarker)
                highlightInline(marker.upperBound..<content.upperBound)
                return
            }

            if MarkdownLineSyntax.isTableDelimiter(text(of: content)) {
                emit(content, .marker)
                return
            }

            highlightInline(content)
        }

        func trimmedTrailingNewline(_ range: Range<Int>) -> Range<Int> {
            var end = range.upperBound
            while end > range.lowerBound, characters[end - 1].isNewline {
                end -= 1
            }
            return range.lowerBound..<end
        }

        func isThematicBreak(_ raw: String) -> Bool {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "-" || first == "*" || first == "_" else { return false }
            let marks = trimmed.filter { $0 == first }
            guard marks.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == first || $0 == " " }
        }

        func atxHeading(in range: Range<Int>) -> (level: Int, contentStart: Int)? {
            var cursor = range.lowerBound
            var indent = 0
            while cursor < range.upperBound, characters[cursor] == " ", indent < 4 {
                cursor += 1
                indent += 1
            }
            guard indent < 4, cursor < range.upperBound, characters[cursor] == "#" else { return nil }
            var level = 0
            while cursor < range.upperBound, characters[cursor] == "#", level < 7 {
                cursor += 1
                level += 1
            }
            guard (1...6).contains(level) else { return nil }
            // `#hashtag` is a tag, not a heading — a space (or end of line) is required.
            guard cursor == range.upperBound || characters[cursor] == " " else { return nil }
            while cursor < range.upperBound, characters[cursor] == " " { cursor += 1 }
            return (level, cursor)
        }

        func listMarker(in range: Range<Int>) -> Range<Int>? {
            var cursor = range.lowerBound
            while cursor < range.upperBound, characters[cursor] == " " || characters[cursor] == "\t" {
                cursor += 1
            }
            guard cursor < range.upperBound else { return nil }
            let start = cursor
            if characters[cursor] == "-" || characters[cursor] == "*" || characters[cursor] == "+" {
                cursor += 1
            } else if characters[cursor].isNumber {
                while cursor < range.upperBound, characters[cursor].isNumber { cursor += 1 }
                guard cursor < range.upperBound, characters[cursor] == "." || characters[cursor] == ")" else {
                    return nil
                }
                cursor += 1
            } else {
                return nil
            }
            // A marker needs a space after it, or `-word` and `1.5` become list items.
            guard cursor < range.upperBound, characters[cursor] == " " else { return nil }
            cursor += 1
            // A task-list checkbox belongs to the marker, so `[ ]` is not read as a link.
            if cursor + 2 < range.upperBound, characters[cursor] == "[",
                characters[cursor + 2] == "]",
                characters[cursor + 1] == " " || characters[cursor + 1] == "x" || characters[cursor + 1] == "X"
            {
                cursor += 3
                if cursor < range.upperBound, characters[cursor] == " " { cursor += 1 }
            }
            return start..<cursor
        }

        // MARK: Inline

        /// One left-to-right pass with a fixed priority order. Code spans come first because
        /// their contents are literal — `` `**not bold**` `` must stay unstyled inside — and the
        /// pass jumps past whatever it matched, so nothing is styled twice.
        ///
        /// A failed opener must not rescan the line for its closer, or a line made of openers is
        /// quadratic and the note typed into freezes: every closer search is answered from an
        /// ``InlineIndex`` built in one pass over the line.
        mutating func highlightInline(_ range: Range<Int>) {
            let index = InlineIndex(characters: characters, range: range)
            var cursor = range.lowerBound
            while cursor < range.upperBound {
                if let next = matchCodeSpan(at: cursor, limit: range.upperBound, index: index)
                    ?? matchWikilink(at: cursor, limit: range.upperBound, index: index)
                    ?? matchLink(at: cursor, limit: range.upperBound, index: index)
                    ?? matchDelimited(at: cursor, limit: range.upperBound, index: index)
                {
                    cursor = next
                } else {
                    cursor += 1
                }
            }
        }

        mutating func matchCodeSpan(at start: Int, limit: Int, index: InlineIndex) -> Int? {
            guard characters[start] == "`" else { return nil }
            let openEnd = index.runEnd(at: start)
            let width = openEnd - start
            // The closer is the first whole run of exactly this many backticks after the opener.
            guard let cursor = index.backtickRuns[width]?.first(atLeast: openEnd) else { return nil }
            let closeEnd = cursor + width
            emit(start..<openEnd, .marker)
            emit(openEnd..<cursor, .inlineCode)
            emit(cursor..<closeEnd, .marker)
            return closeEnd
        }

        mutating func matchWikilink(at start: Int, limit: Int, index: InlineIndex) -> Int? {
            guard start + 1 < limit, characters[start] == "[", characters[start + 1] == "[" else { return nil }
            guard let cursor = index.wikilinkCloses.first(atLeast: start + 2) else { return nil }
            emit(start..<(start + 2), .marker)
            emit((start + 2)..<cursor, .wikilink)
            emit(cursor..<(cursor + 2), .marker)
            return cursor + 2
        }

        mutating func matchLink(at start: Int, limit: Int, index: InlineIndex) -> Int? {
            guard characters[start] == "[" else { return nil }
            guard let closeBracket = index.closeBrackets.first(atLeast: start + 1) else { return nil }
            guard closeBracket + 1 < limit, characters[closeBracket + 1] == "(" else { return nil }
            guard let closeParen = index.closeParens.first(atLeast: closeBracket + 2) else { return nil }
            emit(start..<(start + 1), .marker)
            emit((start + 1)..<closeBracket, .linkText)
            emit(closeBracket..<(closeBracket + 2), .marker)
            emit((closeBracket + 2)..<closeParen, .url)
            emit(closeParen..<(closeParen + 1), .marker)
            return closeParen + 1
        }

        /// `**strong**`, `__strong__`, `*em*`, `_em_`, `~~strike~~`.
        mutating func matchDelimited(at start: Int, limit: Int, index: InlineIndex) -> Int? {
            let character = characters[start]
            guard character == "*" || character == "_" || character == "~" else { return nil }
            let runEnd = index.runEnd(at: start)
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
            // The closer is the first whole run of the character, at least as long as the opener,
            // that does not follow a space.
            guard
                let cursor = index.delimiterRuns[DelimiterKey(character: character, width: width)]?
                    .first(atLeast: runEnd)
            else { return nil }
            emit(start..<runEnd, .marker)
            emit(runEnd..<cursor, style)
            emit(cursor..<(cursor + width), .marker)
            return cursor + width
        }
    }
}

private struct DelimiterKey: Hashable {
    let character: Character
    let width: Int
}

extension Array where Element == Int {
    /// The first element at or after `position`, for an ascending array.
    fileprivate func first(atLeast position: Int) -> Int? {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < position { low = mid + 1 } else { high = mid }
        }
        return low < count ? self[low] : nil
    }
}

/// Where each kind of closer sits on one line, found in a single pass, so that asking for the
/// closer of an opener is a binary search rather than a scan to the end of the line. Every list
/// is ascending and covers only the line's own range.
private struct InlineIndex {
    /// Starts of whole backtick runs, by run length.
    var backtickRuns: [Int: [Int]] = [:]
    /// Starts of `]]`.
    var wikilinkCloses: [Int] = []
    var closeBrackets: [Int] = []
    var closeParens: [Int] = []
    /// Starts of whole runs of `*`, `_` or `~` that follow a character other than a space, listed
    /// under every opener width they can close: a run of `n` closes a width-1 and a width-2 opener
    /// when `n >= 2`, a width-1 one when `n == 1`.
    var delimiterRuns: [DelimiterKey: [Int]] = [:]

    /// Where the run of equal characters containing each position ends, relative to the range.
    /// An opener that fails sits at every position of a long run in turn, so rereading the run
    /// from each of them would be quadratic.
    private var runEnds: [Int]
    private let lowerBound: Int

    func runEnd(at position: Int) -> Int { runEnds[position - lowerBound] }

    init(characters: [Character], range: Range<Int>) {
        lowerBound = range.lowerBound
        runEnds = Array(repeating: range.upperBound, count: range.count)
        var position = range.upperBound - 1
        while position >= range.lowerBound {
            if position + 1 < range.upperBound, characters[position] == characters[position + 1] {
                runEnds[position - range.lowerBound] = runEnds[position + 1 - range.lowerBound]
            } else {
                runEnds[position - range.lowerBound] = position + 1
            }
            position -= 1
        }
        var index = range.lowerBound
        while index < range.upperBound {
            let character = characters[index]
            switch character {
            case "`":
                let end = runEnds[index - range.lowerBound]
                backtickRuns[end - index, default: []].append(index)
                index = end
                continue
            case "*", "_", "~":
                let end = runEnds[index - range.lowerBound]
                // A run at the very start of the line has no character before it, and no opener
                // can lie before it either, so it is never asked for.
                if index > 0, characters[index - 1] != " " {
                    for width in 1...min(end - index, 2) {
                        delimiterRuns[DelimiterKey(character: character, width: width), default: []].append(index)
                    }
                }
                index = end
                continue
            case "]":
                closeBrackets.append(index)
                if index + 1 < range.upperBound, characters[index + 1] == "]" { wikilinkCloses.append(index) }
            case ")":
                closeParens.append(index)
            default:
                break
            }
            index += 1
        }
    }
}
