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
/// A link to a heading — `[[#Heading]]`, `[[#Heading|alias]]`, or `[[Note#Heading]]` naming the note
/// it sits in — is a jump within the page; `[[Other#Heading]]` opens that note at the heading. See
/// ``NoteHeading`` and ``NoteLinkTarget``.
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

    /// Only unreserved characters stay literal in a link's heading: a `)` would end the markdown
    /// destination it is written into, and a space or `#` would end the URL.
    static let fragmentAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A link to a heading of the note it sits in, as markdown. A block reference (`[[#^id]]`)
    /// names no heading and stays as its text.
    static func headingLinkMarkdown(anchor: String, alias: String?) -> String {
        let heading = NoteHeading.linkText(anchor)
        let display = escapeMarkdownText(alias ?? heading ?? anchor)
        guard let heading else { return display }
        return "[\(display)](\(noteLinkURL(id: "", heading: heading)))"
    }

    /// What a non-embed wikilink becomes. An attachment is never inline markdown — it becomes its
    /// own item/segment, since rendering it needs a live fetch; anything else is a real link to
    /// the resolved note (at its heading, when the link names one) or a strikethrough span.
    ///
    /// A link naming the note it sits in (`selfName`) is a heading of this page, whatever the
    /// index says — the same order as the web's `splitBodyForRender`.
    static func rendering(
        of link: Wikilink, nameToId: [String: String], attachmentIndex: AttachmentIndex, selfName: String?
    ) -> BodyLinkRendering {
        let headingText = link.heading.flatMap(NoteHeading.linkText)
        let shown = link.alias ?? headingText.map { "\(link.target) > \($0)" } ?? link.target
        if let headingText, let selfName,
            classifyLocalTarget(link.target).baseTarget.lowercased() == selfName.lowercased()
        {
            return .markdown(headingLinkMarkdown(anchor: headingText, alias: shown))
        }
        switch resolveWikilinkTarget(link.target, nameToId: nameToId, attachmentIndex: attachmentIndex) {
        case .attachment(let relPath):
            return .attachment(relPath: relPath, label: link.alias)
        case .note(let id):
            return .markdown("[\(escapeMarkdownText(shown))](\(noteLinkURL(id: id, heading: headingText)))")
        case .dead:
            return .markdown("~~\(escapeMarkdownText(shown))~~")
        }
    }
}

/// What a wikilink is drawn as — see ``Wikilinks/rendering(of:nameToId:attachmentIndex:selfName:)``.
enum BodyLinkRendering: Equatable {
    case attachment(relPath: String, label: String?)
    case markdown(String)
}

/// A link in a note body that the renderer rewrites: an Obsidian wikilink, or a link to a heading
/// of the same note (`[[#Heading]]`, which names no note and so is no wikilink).
enum BodyLink {
    case wikilink(Wikilink)
    case heading(start: Int, end: Int, anchor: String, alias: String?)

    var start: Int {
        switch self {
        case .wikilink(let link): return link.start
        case .heading(let start, _, _, _): return start
        }
    }

    var end: Int {
        switch self {
        case .wikilink(let link): return link.end
        case .heading(_, let end, _, _): return end
        }
    }
}

extension Wikilinks {
    /// Every rewritable link in `chars`, in document order, outside code.
    static func bodyLinks(in chars: [Character]) -> [BodyLink] {
        let excluded = WikilinkScan.Excluded(WikilinkScan.codeRanges(in: chars))
        var links: [BodyLink] = []
        for match in WikilinkScan.wikilinks(in: chars) where !excluded.contains(match.start) {
            links.append(
                .wikilink(
                    Wikilink(
                        start: match.start, end: match.end, isEmbed: match.isEmbed,
                        target: String(chars[match.target]),
                        heading: match.anchor.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) },
                        alias: match.alias.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) })))
        }
        let wikilinkCount = links.count
        for match in WikilinkScan.headingLinks(in: chars) where !excluded.contains(match.start) {
            links.append(
                .heading(
                    start: match.start, end: match.end, anchor: String(chars[match.heading]),
                    alias: match.alias.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) }))
        }
        // Both runs are already in document order; sorting is only needed when both exist.
        if wikilinkCount > 0, links.count > wikilinkCount { links.sort { $0.start < $1.start } }
        return links
    }
}

/// What a wikilink target resolves to, in `note_links_resolved`'s own three-step priority order.
enum WikilinkResolution: Equatable {
    case attachment(relPath: String)
    case note(id: String)
    case dead
}

/// `[[target]]`, `[[target|alias]]`, `[[target#heading]]` and `![[target]]` in document order. A link
/// to a heading of the note it sits in (`[[#Heading]]`) names no target and is no wikilink here;
/// ``Wikilinks/bodyLinks(in:)`` carries both.
///
/// Linear in the body, whatever it says: ``WikilinkScan`` does the scanning and
/// `NoteWikilinkScanTests` holds it to the `Regex` it replaced.
public func findWikilinks(_ body: String) -> [Wikilink] {
    findWikilinks(in: Array(body))
}

func findWikilinks(in chars: [Character]) -> [Wikilink] {
    let excluded = WikilinkScan.Excluded(WikilinkScan.codeRanges(in: chars))
    var results: [Wikilink] = []
    for match in WikilinkScan.wikilinks(in: chars) where !excluded.contains(match.start) {
        results.append(
            Wikilink(
                start: match.start, end: match.end, isEmbed: match.isEmbed,
                target: String(chars[match.target]),
                heading: match.anchor.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) },
                alias: match.alias.map { String(chars[($0.lowerBound + 1)..<$0.upperBound]) }))
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
    /// `label` is the link's alias — what the note calls the file, which a chip shows instead of
    /// the stored name (an upload is stored under a generated one).
    case attachmentLink(relPath: String, label: String?)
}

/// What a file chip shows and what it saves under, given the stored path and the link's label.
///
/// The label is shown whenever it is non-blank. It is also the saved name, but only when it keeps
/// the stored file's extension — a label such as "Q3 numbers" must not turn a PDF into a file the
/// system cannot open.
public struct AttachmentChipName: Equatable, Sendable {
    public let shown: String
    public let saved: String

    public init(storedName: String, label: String?) {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        shown = trimmed.isEmpty ? storedName : trimmed
        saved = Self.extensionOf(shown) == Self.extensionOf(storedName) ? shown : storedName
    }

    private static func extensionOf(_ name: String) -> String {
        (name as NSString).pathExtension.lowercased()
    }
}

/// The URL a resolved wikilink is turned into: the app's own deep link to that note.
///
/// The same form a home-screen shortcut and a tapped notification produce, rather than a scheme
/// of its own. The note body renderer intercepts it and navigates in place — but if one ever
/// escapes to the system, it round-trips back through `onOpenURL` and lands on the right note,
/// which a private scheme could not do.
///
/// A `heading` rides in the fragment, which the deep link's own parser ignores, so a link that
/// escapes to the system still opens the right note. An empty `id` is a heading of the note the
/// link sits in (`pai://note#Heading`). Read back with ``NoteLinkTarget/parse(_:)``.
public func noteLinkURL(id: String, heading: String? = nil) -> String {
    let base = id.isEmpty ? "pai://note" : (DeepLink.note(id: id).url?.absoluteString ?? "")
    guard !base.isEmpty, let heading, !heading.isEmpty else { return base }
    return base + "#" + (heading.addingPercentEncoding(withAllowedCharacters: Wikilinks.fragmentAllowed) ?? heading)
}

/// `nameToId` keys are lowercased note names; a target is matched by its last path component,
/// since a container is a flat folder and Obsidian itself resolves a bare wikilink the same way.
/// `attachmentIndex` is consulted first (an exact path match beats a note-name match, mirroring
/// `note_links_resolved`) — defaults to empty, so a caller with no attachments loaded yet still
/// gets note/dead resolution rather than every wikilink reading as dead.
public func splitBodyForRender(
    _ body: String, nameToId: [String: String], attachmentIndex: AttachmentIndex = .empty, selfName: String? = nil
) -> [NoteBodySegment] {
    let chars = Array(body)
    let links = Wikilinks.bodyLinks(in: chars)
    guard !links.isEmpty else { return [.text(body)] }

    var segments: [NoteBodySegment] = []
    var textParts: [String] = []
    var cursor = 0

    func flushText() {
        guard !textParts.isEmpty else { return }
        segments.append(.text(textParts.joined()))
        textParts = []
    }

    for item in links {
        if item.start < cursor { continue }
        if item.start > cursor { textParts.append(String(chars[cursor..<item.start])) }
        switch item {
        case .heading(_, _, let anchor, let alias):
            textParts.append(Wikilinks.headingLinkMarkdown(anchor: anchor, alias: alias))
        case .wikilink(let link) where link.isEmbed:
            flushText()
            segments.append(.embed(target: link.target, alias: link.alias))
        case .wikilink(let link):
            switch Wikilinks.rendering(
                of: link, nameToId: nameToId, attachmentIndex: attachmentIndex, selfName: selfName)
            {
            case .attachment(let relPath, let label):
                flushText()
                segments.append(.attachmentLink(relPath: relPath, label: label))
            case .markdown(let markdown):
                textParts.append(markdown)
            }
        }
        cursor = item.end
    }
    if cursor < chars.count { textParts.append(String(chars[cursor...])) }
    flushText()
    return segments
}
