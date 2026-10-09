import Foundation

/// One heading, with its Character offset into the body so a jump can go straight there rather
/// than merely scrolling by heading index.
public struct OutlineEntry: Equatable, Sendable, Identifiable {
    public let level: Int
    public let text: String
    public let offset: Int

    public var id: Int { offset }
}

/// ATX-style markdown headings only (`# `..`###### `) — the toolbar this app's editor offers
/// never produces setext (`===`/`---`) headings, so parsing for them would find headings the
/// editor itself cannot create. Lines inside a fenced code block (``` or ~~~, CommonMark's
/// opening/closing rules; an unclosed fence runs to the end) are code, never headings — the web
/// outline reads a real parse tree and agrees.
public func parseOutline(_ body: String) -> [OutlineEntry] {
    var entries: [OutlineEntry] = []
    var offset = 0
    var openFence: String?
    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
        defer { offset += line.count + 1 }
        let text = String(line)
        if let fence = openFence {
            if MarkdownLineSyntax.closesFence(text, opener: fence) { openFence = nil }
            continue
        }
        if let fence = MarkdownLineSyntax.openingFence(in: text) {
            openFence = fence
            continue
        }
        if let heading = atxHeading(in: line) {
            entries.append(OutlineEntry(level: heading.level, text: String(heading.text), offset: offset))
        }
    }
    return entries
}

/// One ATX heading line: `^(#{1,6})\s+(.+?)\s*$`, read by hand because that pattern is quadratic
/// on a heading followed by a long whitespace run, and a note body can be written by someone
/// else. `NoteOutlineScanTests` holds this to the pattern.
///
/// The pattern's lazy `.+?` stops at the last non-whitespace character, so the text is everything
/// between the whitespace after the hashes and the whitespace before the line's end. A line with
/// nothing but whitespace after the hashes still matches when that run is at least two long,
/// because `\s+` gives one back for `.+?` to take — the text is then that one whitespace
/// character, the last one the `.` accepts (it refuses line-break characters).
private func atxHeading(in line: Substring) -> (level: Int, text: Substring)? {
    var level = 0
    var i = line.startIndex
    while i < line.endIndex, line[i] == "#" {
        level += 1
        i = line.index(after: i)
    }
    guard (1...6).contains(level), i < line.endIndex, line[i].isWhitespace else { return nil }

    let spaceStart = i
    var lastNonSpace: Substring.Index?
    var lastNonBreak: Substring.Index?  // among the whitespace after the first one
    var firstText: Substring.Index?
    while i < line.endIndex {
        let c = line[i]
        if c.isWhitespace {
            if i != spaceStart, !c.isNewline { lastNonBreak = i }
        } else {
            if firstText == nil { firstText = i }
            lastNonSpace = i
        }
        i = line.index(after: i)
    }

    guard let firstText, let lastNonSpace else {
        guard let lastNonBreak else { return nil }
        return (level, line[lastNonBreak...lastNonBreak])
    }
    // `.` refuses a line-break character anywhere in the text it spans.
    var j = firstText
    let end = line.index(after: lastNonSpace)
    while j < end {
        if line[j].isNewline { return nil }
        j = line.index(after: j)
    }
    return (level, line[firstText..<end])
}
