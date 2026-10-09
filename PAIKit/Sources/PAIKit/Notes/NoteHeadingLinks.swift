import Foundation

/// Heading anchors: what `[[#Heading]]` and `[[Note#Heading]]` name, and how a heading's text
/// becomes the comparable form a jump looks it up by. Port of `pai-cloud/web/src/apps/notes/
/// headingSlug.ts`; keep the two in agreement.
public enum NoteHeading {

    /// Lowercase, letters and digits kept, everything else collapsed to a single `-`, trimmed — an
    /// empty result (a heading that was only punctuation) becomes `section`.
    public static func slug(_ text: String) -> String {
        var out = ""
        var pendingDash = false
        for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars {
            if isLetterOrNumber(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "section" : out
    }

    /// The heading a `[[Note#Heading]]` link names, as text: the last `#` segment
    /// (`[[Note#Parent#Child]]` is Obsidian's path to Child), trimmed. `nil` for what is not a
    /// heading at all — a block reference (`#^id`) or nothing.
    public static func linkText(_ anchor: String) -> String? {
        let last = anchor.split(separator: "#", omittingEmptySubsequences: false).last.map(String.init) ?? anchor
        let trimmed = last.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.hasPrefix("^") ? nil : trimmed
    }

    /// The Character offset of the first heading in `body` that `heading` names — the first such
    /// heading is the one that keeps the bare slug under the outline's duplicate numbering, and
    /// the one Obsidian jumps to. The offset counts in the unit ``parseOutline(_:)`` does.
    public static func offset(of heading: String, in body: String) -> Int? {
        let wanted = slug(heading)
        return parseOutline(body).first { slug($0.text) == wanted }?.offset
    }

    private static func isLetterOrNumber(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}

/// Which note, and optionally which heading of it, a note link names. An empty `id` is a heading
/// of the note the link sits in.
public struct NoteLinkTarget: Equatable, Sendable {
    public let id: String
    public let heading: String?

    public init(id: String, heading: String?) {
        self.id = id
        self.heading = heading
    }

    /// Reads the URL ``noteLinkURL(id:heading:)`` writes: `pai://note/<id>`, `pai://note/<id>#<heading>`,
    /// or `pai://note#<heading>`. Anything else is not a note link.
    public static func parse(_ url: URL) -> NoteLinkTarget? {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let heading = components?.fragment.flatMap { $0.isEmpty ? nil : $0 }
        if case .note(let id)? = DeepLink.from(url: url) { return NoteLinkTarget(id: id, heading: heading) }
        guard let heading, components?.scheme?.lowercased() == "pai", components?.host?.lowercased() == "note",
            components?.path.isEmpty != false || components?.path == "/"
        else { return nil }
        return NoteLinkTarget(id: "", heading: heading)
    }
}
