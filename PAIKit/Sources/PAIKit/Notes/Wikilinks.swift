import Foundation

/// Finding Obsidian wikilinks in a note body, for DISPLAY only — resolving a `[[target]]`
/// against the loaded note index and turning it into something clickable, or visibly dead when
/// it resolves to nothing.
///
/// Swift port of `pai-cloud/web/src/apps/notes/wikilinks.ts`'s grammar: `[[target]]`,
/// `[[target|alias]]`, `[[target#heading]]`, and the embed form `![[target]]` — fenced code
/// blocks and inline code spans are excluded from the scan so a shell snippet's
/// `if [[ "$X" == *"-"* ]]` is never mistaken for a link. Keep this in agreement with that
/// grammar if either changes; neither module can import the other.
///
/// `start`/`end` are Character offsets into the body (not UTF-8 or UTF-16 byte offsets) — the
/// same convention ``parseOutline(_:)`` and ``findOccurrences(body:query:)`` use, so an offset
/// from any of the three names the same position.
public struct Wikilink: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let isEmbed: Bool
    public let target: String
    public let heading: String?
    public let alias: String?
}

enum Wikilinks {
    /// Character ranges (fenced code blocks, then inline code spans) to exclude from a wikilink
    /// scan. Mirrors the web's `codeRanges` — same CommonMark fence-matching rule: a closing
    /// fence needs the same character and at least the same length as its opener.
    static func codeRanges(in body: String) -> [Range<Int>] {
        // Declared locally rather than as top-level `let`s: `Regex` is not `Sendable`, so a
        // shared global fails Swift 6 strict concurrency — see the `ios` skill's own note.
        let fencePrefix = /^[ \t]{0,3}(`{3,}|~{3,})/
        let spanPattern = /(`+)([^`\n]*?)\1/
        var ranges: [Range<Int>] = []
        var openFence: (char: Character, len: Int, start: Int)?
        var offset = 0
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            let hasNewline = index < lines.count - 1
            if let match = try? fencePrefix.firstMatch(in: line) {
                let fenceRun = String(match.output.1)
                let fenceChar = fenceRun.first!
                let fenceLen = fenceRun.count
                if let open = openFence {
                    if fenceChar == open.char, fenceLen >= open.len {
                        ranges.append(open.start..<(hasNewline ? offset + line.count + 1 : offset + line.count))
                        openFence = nil
                    }
                } else {
                    openFence = (fenceChar, fenceLen, offset)
                }
            }
            offset += line.count + (hasNewline ? 1 : 0)
        }
        if let open = openFence { ranges.append(open.start..<body.count) }

        // Inline code spans: `foo`, ``foo ` bar``, … — a run of backticks, then anything up to a
        // matching run of the same length.
        for match in body.matches(of: spanPattern) {
            let start = body.distance(from: body.startIndex, to: match.range.lowerBound)
            let end = body.distance(from: body.startIndex, to: match.range.upperBound)
            ranges.append(start..<end)
        }
        return ranges
    }

    static func isInside(_ pos: Int, _ ranges: [Range<Int>]) -> Bool {
        ranges.contains { $0.contains(pos) }
    }

    /// Escapes characters that would otherwise be read as markdown syntax inside a generated
    /// link label or strikethrough span — a note title is free text, not markdown source, by the
    /// time it lands here.
    static func escapeMarkdownText(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            if "\\`*_[]~".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// `[[target]]`, `[[target|alias]]`, `[[target#heading]]` and `![[target]]` in document order.
public func findWikilinks(_ body: String) -> [Wikilink] {
    // Declared locally rather than as a top-level `let`: `Regex` is not `Sendable`, so a shared
    // global fails Swift 6 strict concurrency — see the `ios` skill's own note on this trap.
    let wikilinkPattern = /(!)?\[\[([^\]|#\n]+)(#[^\]|\n]+)?(\|[^\]\n]+)?\]\]/
    let excluded = Wikilinks.codeRanges(in: body)
    var results: [Wikilink] = []
    for match in body.matches(of: wikilinkPattern) {
        let start = body.distance(from: body.startIndex, to: match.range.lowerBound)
        if Wikilinks.isInside(start, excluded) { continue }
        let end = body.distance(from: body.startIndex, to: match.range.upperBound)
        let (_, bang, target, heading, alias) = match.output
        results.append(
            Wikilink(
                start: start, end: end, isEmbed: bang != nil, target: String(target),
                heading: heading.map { String($0.dropFirst()) },
                alias: alias.map { String($0.dropFirst()) }))
    }
    return results
}

/// A note body decomposed into markdown text runs and attachment embeds (`![[...]]`), with every
/// plain wikilink already turned into a normal markdown link (resolved) or a strikethrough span
/// (dead) inside the text runs — so a text segment can go straight to a markdown renderer with no
/// further wikilink awareness there.
public enum NoteBodySegment: Equatable, Sendable {
    case text(String)
    case embed(target: String, alias: String?)
}

/// The URL a resolved wikilink is turned into: the app's own deep link to that note.
///
/// The same form a home-screen shortcut and a tapped notification produce, rather than a scheme
/// of its own. The note body renderer intercepts it and navigates in place — but if one ever
/// escapes to the system, it round-trips back through `onOpenURL` and lands on the right note,
/// which a private scheme could not do.
public func noteLinkURL(id: String) -> String {
    DeepLink.note(id: id).url?.absoluteString ?? ""
}

/// `nameToId` keys are lowercased note names; a target is matched by its last path component,
/// since a container is a flat folder and Obsidian itself resolves a bare wikilink the same way.
public func splitBodyForRender(_ body: String, nameToId: [String: String]) -> [NoteBodySegment] {
    let links = findWikilinks(body)
    guard !links.isEmpty else { return [.text(body)] }

    let chars = Array(body)
    var segments: [NoteBodySegment] = []
    var textParts: [String] = []
    var cursor = 0

    func flushText() {
        guard !textParts.isEmpty else { return }
        segments.append(.text(textParts.joined()))
        textParts = []
    }

    for link in links {
        if link.start > cursor { textParts.append(String(chars[cursor..<link.start])) }
        if link.isEmbed {
            flushText()
            segments.append(.embed(target: link.target, alias: link.alias))
        } else {
            let display = Wikilinks.escapeMarkdownText(link.alias ?? link.target)
            let basename =
                link.target.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? link.target
            if let resolvedId = nameToId[basename.lowercased()] {
                textParts.append("[\(display)](\(noteLinkURL(id: resolvedId)))")
            } else {
                textParts.append("~~\(display)~~")
            }
        }
        cursor = link.end
    }
    if cursor < chars.count { textParts.append(String(chars[cursor...])) }
    flushText()
    return segments
}
