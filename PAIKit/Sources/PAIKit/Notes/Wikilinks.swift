import Foundation

/// Finding Obsidian wikilinks in a note body, for DISPLAY only — resolving a `[[target]]`
/// against the loaded note and attachment indexes and turning it into something clickable, or
/// visibly dead when it resolves to nothing.
///
/// Swift port of `pai-cloud/web/src/apps/notes/wikilinks.ts`'s grammar: `[[target]]`,
/// `[[target|alias]]`, `[[target#heading]]`, and the embed form `![[target]]` — fenced code
/// blocks and inline code spans are excluded from the scan so a shell snippet's
/// `if [[ "$X" == *"-"* ]]` is never mistaken for a link. Keep this in agreement with that
/// grammar if either changes; neither module can import the other.
///
/// Resolution mirrors the web's own `resolveWikilinkTarget`, in turn mirroring the pod's
/// `note_links_resolved` view: an attachment match by full path wins over a note match by name,
/// which in turn wins over an attachment match by bare filename. Unlike the web, this module does
/// not additionally scan plain markdown-syntax links (`[alias](attachments/foo)`) for an
/// attachment target — only the `[[wikilink]]` forms above; see the module's own note on this
/// narrower scope where ``resolveWikilinkTarget(_:nameToId:attachmentIndex:)`` is declared.
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

/// A container's attachment inventory, shaped for the two ways wikilink resolution looks one up:
/// the exact container-root-relative path, or the last path segment case-folded (Obsidian's own
/// fallback). Mirrors the web's `AttachmentIndex` (`wikilinks.ts`). Values are the attachment's
/// real `relPath` — what fetching it needs, which is not always the same string the link wrote
/// when only the basename matched.
public struct AttachmentIndex: Sendable {
    let byPath: [String: String]
    let byBasenameKey: [String: String]

    public static let empty = AttachmentIndex(byPath: [:], byBasenameKey: [:])
}

/// `byBasenameKey` keeps the alphabetically-first `relPath` on a basename collision, mirroring
/// the pod's `note_links_resolved` (`ORDER BY a.rel_path LIMIT 1`) and the web's own
/// `buildAttachmentIndex` — a flat `attachments/` folder makes a real collision rare, but the
/// tie-break should still agree with the server's rather than depend on fetch order.
public func buildAttachmentIndex(_ attachments: [NoteAttachmentRecord]) -> AttachmentIndex {
    var byPath: [String: String] = [:]
    var byBasenameKey: [String: String] = [:]
    for attachment in attachments.sorted(by: { $0.relPath < $1.relPath }) {
        byPath[attachment.relPath] = attachment.relPath
        let key = attachment.basename.lowercased()
        if byBasenameKey[key] == nil { byBasenameKey[key] = attachment.relPath }
    }
    return AttachmentIndex(byPath: byPath, byBasenameKey: byBasenameKey)
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

    /// Percent-decodes and strips a leading `./` and a trailing `.md` — mirrors
    /// `classifyLocalTarget` in the web's `wikilinks.ts` and `_normalize_path` in
    /// `pai_cloud.notesync_links`, minus the `escapesContainer` bookkeeping neither renderer
    /// needs. A malformed escape is kept as written rather than thrown on.
    static func classifyLocalTarget(_ text: String) -> (pathTarget: String, baseTarget: String) {
        var decoded = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let unescaped = decoded.removingPercentEncoding { decoded = unescaped }
        if decoded.hasPrefix("./") { decoded = String(decoded.dropFirst(2)) }
        if decoded.hasSuffix(".md") { decoded = String(decoded.dropLast(3)) }
        let baseTarget =
            decoded.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? decoded
        return (pathTarget: decoded, baseTarget: baseTarget)
    }

    /// Resolves an already-decoded local target against the attachment index by its full path
    /// (the `.md`-appended form too) — the first of `note_links_resolved`'s two attachment steps.
    static func resolveAttachment(_ pathTarget: String, in index: AttachmentIndex) -> String? {
        index.byPath[pathTarget] ?? index.byPath["\(pathTarget).md"]
    }

    static func resolveAttachmentByBasename(_ baseTarget: String, in index: AttachmentIndex) -> String? {
        let key = baseTarget.lowercased()
        return index.byBasenameKey[key] ?? index.byBasenameKey["\(key).md"]
    }

    /// The full three-step order `note_links_resolved` applies to a wikilink target: an
    /// attachment by exact path, then a note by name, then an attachment by bare filename.
    static func resolveWikilinkTarget(
        _ rawTarget: String, nameToId: [String: String], attachmentIndex: AttachmentIndex
    ) -> WikilinkResolution {
        let (pathTarget, baseTarget) = classifyLocalTarget(rawTarget)
        if let byPath = resolveAttachment(pathTarget, in: attachmentIndex) {
            return .attachment(relPath: byPath)
        }
        if let noteId = nameToId[baseTarget.lowercased()] {
            return .note(id: noteId)
        }
        if let byBasename = resolveAttachmentByBasename(baseTarget, in: attachmentIndex) {
            return .attachment(relPath: byBasename)
        }
        return .dead
    }

    /// The inline markdown a resolved-to-note or dead wikilink becomes: a real link to the
    /// resolved note, or a strikethrough span. An attachment resolution is never turned into
    /// inline markdown text — it becomes its own item/segment instead, since rendering it needs a
    /// live fetch; callers branch on ``WikilinkResolution`` before reaching here.
    static func inlineMarkdown(display: String, resolution: WikilinkResolution) -> String {
        switch resolution {
        case .note(let id):
            return "[\(display)](\(noteLinkURL(id: id)))"
        case .attachment, .dead:
            return "~~\(display)~~"
        }
    }
}

/// What a wikilink target resolves to, in `note_links_resolved`'s own three-step priority order.
enum WikilinkResolution: Equatable {
    case attachment(relPath: String)
    case note(id: String)
    case dead
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

/// A note body decomposed into markdown text runs, attachment embeds (`![[...]]`), and resolved
/// attachment links — a plain wikilink whose target resolves to a real file rather than a note.
/// Every plain wikilink that resolves to neither is turned into a strikethrough span inside the
/// surrounding text run, so a text segment can go straight to a markdown renderer with no further
/// wikilink awareness there.
public enum NoteBodySegment: Equatable, Sendable {
    case text(String)
    case embed(target: String, alias: String?)
    case attachmentLink(relPath: String)
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
/// `attachmentIndex` is consulted first (an exact path match beats a note-name match, mirroring
/// `note_links_resolved`) — defaults to empty, so a caller with no attachments loaded yet still
/// gets note/dead resolution rather than every wikilink reading as dead.
public func splitBodyForRender(
    _ body: String, nameToId: [String: String], attachmentIndex: AttachmentIndex = .empty
) -> [NoteBodySegment] {
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
            let resolution = Wikilinks.resolveWikilinkTarget(
                link.target, nameToId: nameToId, attachmentIndex: attachmentIndex)
            if case .attachment(let relPath) = resolution {
                flushText()
                segments.append(.attachmentLink(relPath: relPath))
            } else {
                let display = Wikilinks.escapeMarkdownText(link.alias ?? link.target)
                textParts.append(Wikilinks.inlineMarkdown(display: display, resolution: resolution))
            }
        }
        cursor = link.end
    }
    if cursor < chars.count { textParts.append(String(chars[cursor...])) }
    flushText()
    return segments
}
