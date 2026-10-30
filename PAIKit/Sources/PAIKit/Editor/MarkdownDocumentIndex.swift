import Foundation

/// What an open note's editor knows about the note's lines, kept current edit by edit.
///
/// Everything an editor asks on a keystroke — is the caret in a code block, which line number
/// starts here, what must be repainted now — has an answer that depends on the lines above it, so
/// asking the text means a walk from the top of the note on every key. This holds those answers
/// and updates them from the edit alone: one lookup is a binary search, and an edit rereads the
/// lines it touched plus however many below it changed their block state, which for ordinary
/// typing is none.
///
/// Reads the text as an `NSString` and speaks UTF-16 offsets, which is what a text storage holds
/// and reports edits in. A text storage's `mutableString` costs nothing to hand over, where its
/// `string` copies the whole note.
public struct MarkdownDocumentIndex: Sendable, Equatable {

    /// The block a line is inside of as it begins.
    public enum BlockState: Equatable, Sendable {
        case body
        case frontmatter
        /// Inside a fenced code block, carrying the fence that opened it.
        case fence(String)
    }

    /// The start of every line, ascending. Text ending in a terminator has a last, empty line
    /// starting at ``length``, which is where a caret after that terminator sits.
    public private(set) var lineStarts: [Int]
    private var entryStates: [BlockState]
    /// The line holding the closing `---`, when the note opens with frontmatter.
    private var frontmatterEnd: Int?
    public private(set) var length: Int

    public init(text: NSString) {
        length = text.length
        lineStarts = Self.lineStarts(in: text, from: 0, to: text.length, includingEnd: true)
        entryStates = []
        entryStates.reserveCapacity(lineStarts.count)
        frontmatterEnd = nil
        frontmatterEnd = findFrontmatterEnd(in: text)
        var state = firstLineState
        for line in lineStarts.indices {
            entryStates.append(state)
            state = exitState(ofLine: line, entry: state, in: text)
        }
    }

    public var lineCount: Int { lineStarts.count }

    /// The line a UTF-16 offset sits on. An offset right after a terminator is on the next line.
    public func line(containing offset: Int) -> Int {
        var low = 0
        var high = lineStarts.count
        while low + 1 < high {
            let middle = (low + high) / 2
            if lineStarts[middle] <= offset { low = middle } else { high = middle }
        }
        return low
    }

    /// The whole line, terminator included.
    public func rangeOfLine(_ line: Int) -> NSRange {
        let end = line + 1 < lineStarts.count ? lineStarts[line + 1] : length
        return NSRange(location: lineStarts[line], length: end - lineStarts[line])
    }

    /// The 1-based number of the line beginning exactly at `offset`, or nil when `offset` is
    /// partway through a line — the continuation of a wrapped one has no number of its own.
    public func lineNumber(startingAt offset: Int) -> Int? {
        let found = line(containing: offset)
        return lineStarts[found] == offset ? found + 1 : nil
    }

    /// Whether a caret here is inside a fenced code block. The line that opens or closes a fence
    /// answers for what comes into it, so a caret on an opener is still outside.
    public func isInsideFence(_ offset: Int) -> Bool {
        if case .fence = entryStates[line(containing: offset)] { return true }
        return false
    }

    /// Bring the index up to date with one processed text edit, in the terms a text storage
    /// reports it: `editedRange` in the text as it now is, and the change in length.
    ///
    /// Returns the whole lines whose styling may have changed. That is the edited lines alone
    /// unless the edit moved a block boundary, when it runs on to the last line that changed
    /// block.
    @discardableResult
    public mutating func applyEdit(editedRange: NSRange, delta: Int, in text: NSString) -> NSRange {
        let oldEditEnd = editedRange.upperBound - delta
        // One line back, because an edit can join or split a CRLF pair across a line boundary.
        let firstLine = max(0, line(containing: editedRange.location) - 1)
        let lastOldLine = line(containing: oldEditEnd)
        let regionStart = lineStarts[firstLine]
        let regionEnd =
            lastOldLine + 1 < lineStarts.count ? lineStarts[lastOldLine + 1] + delta : text.length

        let rescanned = Self.lineStarts(
            in: text, from: regionStart, to: regionEnd, includingEnd: lastOldLine + 1 == lineStarts.count)
        let firstEntry = entryStates[firstLine]
        var newStarts = rescanned
        newStarts.append(contentsOf: lineStarts[(lastOldLine + 1)...].map { $0 + delta })
        lineStarts.replaceSubrange(firstLine..., with: newStarts)
        // A placeholder for the rescanned lines, whose real states the walk below writes.
        var newStates = [BlockState](repeating: .body, count: rescanned.count)
        newStates.append(contentsOf: entryStates[(lastOldLine + 1)...])
        entryStates.replaceSubrange(firstLine..., with: newStates)
        length = text.length

        let oldFrontmatterEnd = frontmatterEnd
        if firstLine <= oldFrontmatterEnd ?? Int.max { frontmatterEnd = findFrontmatterEnd(in: text) }
        let walkStart = frontmatterEnd == oldFrontmatterEnd ? firstLine : 0
        var state = walkStart == 0 ? firstLineState : firstEntry
        let lastRescanned = firstLine + rescanned.count - 1

        var line = walkStart
        while line < lineStarts.count {
            if line > lastRescanned, entryStates[line] == state { break }
            entryStates[line] = state
            state = exitState(ofLine: line, entry: state, in: text)
            line += 1
        }

        let end = line < lineStarts.count ? lineStarts[line] : length
        return NSRange(location: lineStarts[walkStart], length: end - lineStarts[walkStart])
    }

    /// How to paint the lines overlapping `range`, in document offsets, in painting order.
    public func spans(overlapping range: NSRange, in text: NSString) -> [MarkdownSourceSpan] {
        var spans: [MarkdownSourceSpan] = []
        let last = line(containing: max(range.location, range.upperBound - 1))
        for line in self.line(containing: range.location)...last {
            let lineRange = rangeOfLine(line)
            guard lineRange.length > 0 else { continue }
            let source = text.substring(with: lineRange)
            switch entryStates[line] {
            case .frontmatter:
                appendFrontmatter(lineRange, to: &spans)
            case .fence(let opener):
                let style: MarkdownSourceStyle =
                    MarkdownLineSyntax.closesFence(source, opener: opener) ? .marker : .codeBlockContent
                spans.append(
                    MarkdownSourceSpan(location: lineRange.location, length: lineRange.length, style: style))
            case .body:
                if MarkdownLineSyntax.openingFence(in: source) != nil {
                    spans.append(
                        MarkdownSourceSpan(location: lineRange.location, length: lineRange.length, style: .marker))
                } else {
                    spans += MarkdownSourceHighlighter.spans(forLine: source, at: lineRange.location)
                }
            }
        }
        return spans
    }

    /// The list lines overlapping `range` that want a hanging indent.
    public func hangingIndents(overlapping range: NSRange, in text: NSString) -> [MarkdownHangingIndent] {
        let last = line(containing: max(range.location, range.upperBound - 1))
        return (self.line(containing: range.location)...last).compactMap { line in
            let lineRange = rangeOfLine(line)
            guard lineRange.length > 0 else { return nil }
            return MarkdownHangingIndent.indent(
                forLine: text.substring(with: lineRange), at: lineRange.location)
        }
    }

    // MARK: Private

    private func appendFrontmatter(_ range: NSRange, to spans: inout [MarkdownSourceSpan]) {
        if let previous = spans.last, previous.style == .frontmatter, previous.end == range.location {
            spans[spans.count - 1] = MarkdownSourceSpan(
                location: previous.location, length: previous.length + range.length, style: .frontmatter)
        } else {
            spans.append(MarkdownSourceSpan(location: range.location, length: range.length, style: .frontmatter))
        }
    }

    private var firstLineState: BlockState { frontmatterEnd == nil ? .body : .frontmatter }

    private func exitState(ofLine line: Int, entry: BlockState, in text: NSString) -> BlockState {
        switch entry {
        case .frontmatter:
            return line == frontmatterEnd ? .body : .frontmatter
        case .fence(let opener):
            let source = text.substring(with: rangeOfLine(line))
            return MarkdownLineSyntax.closesFence(source, opener: opener) ? .body : entry
        case .body:
            let source = text.substring(with: rangeOfLine(line))
            return MarkdownLineSyntax.openingFence(in: source).map(BlockState.fence) ?? .body
        }
    }

    private func lineIsFrontmatterDelimiter(_ line: Int, in text: NSString) -> Bool {
        text.substring(with: rangeOfLine(line)).trimmingCharacters(in: .whitespacesAndNewlines) == "---"
    }

    /// An unterminated block is not frontmatter, which is why the close has to be found before
    /// the first line can be classified.
    private func findFrontmatterEnd(in text: NSString) -> Int? {
        guard lineStarts.count > 1, lineIsFrontmatterDelimiter(0, in: text) else { return nil }
        return (1..<lineStarts.count).first { lineIsFrontmatterDelimiter($0, in: text) }
    }

    /// Line starts within `start..<end`, by the rule `Character.isNewline` applies: a CRLF pair is
    /// one terminator. A start at `end` itself is the caller's to ask for: it is the document's
    /// last line, or the next line the caller already holds.
    private static func lineStarts(in text: NSString, from start: Int, to end: Int, includingEnd: Bool) -> [Int] {
        var units = [unichar](repeating: 0, count: end - start)
        text.getCharacters(&units, range: NSRange(location: start, length: end - start))
        var starts = [start]
        var index = 0
        while index < units.count {
            let unit = units[index]
            index += 1
            guard isTerminator(unit) else { continue }
            if unit == 0x0D, index < units.count, units[index] == 0x0A { index += 1 }
            let next = start + index
            if next < end || includingEnd { starts.append(next) }
        }
        return starts
    }

    private static func isTerminator(_ unit: unichar) -> Bool {
        switch unit {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029: return true
        default: return false
        }
    }
}
