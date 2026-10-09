import Foundation

/// One action the note editor's formatting bar can offer.
///
/// Port of `pai-cloud/web/src/apps/notes/toolbarConfig.ts`'s `ToolbarButtonId` — not the same ids
/// (`bullet` there, `bulletList` here, matching `MarkdownCommand`'s own naming instead), but the
/// same shape: a stable string identity a layout persists by, a label and icon for display, and a
/// `Codable` raw value that survives a build gaining or losing a case. The raw value is also what
/// ``MarkdownCommand`` uses for every case here that drives one — see ``command``.
public enum NoteToolbarActionId: String, Codable, Sendable, CaseIterable, Hashable {
    case undo, redo, attach
    case heading, bold, italic, bulletList, checkbox, outdent, indent, inlineCode, codeBlock, quote, link

    /// The markdown command this action drives, or `nil` for the four that are not one:
    /// undo/redo delegate to the text view's own undo manager, attach opens a file picker and link
    /// opens its form (see ``MarkdownLinkEditing``).
    public var command: MarkdownCommand? { MarkdownCommand(rawValue: rawValue) }

    /// Whether the action writes markup into the note — everything but undo, redo and attach —
    /// and so is withheld while the caret is inside a fenced code block.
    public var editsMarkup: Bool {
        switch self {
        case .undo, .redo, .attach: return false
        default: return true
        }
    }

    /// Shown in the settings list and as the bar button's accessible name.
    public var label: String {
        switch self {
        case .undo: return "Undo"
        case .redo: return "Redo"
        case .attach: return "Attach a photo or file"
        case .heading: return "Heading"
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .bulletList: return "Bulleted list"
        case .checkbox: return "Checklist item"
        case .outdent: return "Outdent"
        case .indent: return "Indent"
        case .inlineCode: return "Code"
        case .codeBlock: return "Code block"
        case .quote: return "Quote"
        case .link: return "Link"
        }
    }

    /// The SF Symbol the bar draws for this action.
    public var symbolName: String {
        switch self {
        case .undo: return "arrow.uturn.backward"
        case .redo: return "arrow.uturn.forward"
        case .attach: return "paperclip"
        case .heading: return "textformat.size"
        case .bold: return "bold"
        case .italic: return "italic"
        case .bulletList: return "list.bullet"
        case .checkbox: return "checklist"
        case .outdent: return "decrease.indent"
        case .indent: return "increase.indent"
        case .inlineCode: return "chevron.left.forwardslash.chevron.right"
        case .codeBlock: return "curlybraces.square"
        case .quote: return "text.quote"
        case .link: return "link"
        }
    }
}

/// Which actions the formatting bar shows, in which order, and how a stored choice is kept safe
/// across a build that adds or removes an action.
///
/// A persisted layout names only the *enabled* actions, in the user's own order — same as the
/// web's `toolbarConfig.ts`. An action absent from it is simply off; there is no separate stored
/// "disabled" list, so the settings screen derives one by subtracting from ``allActionsInDefaultOrder``.
public enum NoteToolbarLayout {

    /// Every action, in the order the settings screen lists a disabled one.
    public static let allActionsInDefaultOrder: [NoteToolbarActionId] = [
        .undo, .redo, .link, .attach,
        .heading, .bold, .italic, .bulletList, .checkbox, .outdent, .indent, .inlineCode, .codeBlock, .quote,
    ]

    /// Matches the web editor's own default (`toolbarConfig.ts`'s `DEFAULT_TOOLBAR_LAYOUT`):
    /// undo, redo, link, attach, bullet, checkbox, outdent, indent, heading, bold, italic, inline
    /// code, code block.
    public static let defaultLayout: [NoteToolbarActionId] = [
        .undo, .redo, .link, .attach, .bulletList, .checkbox, .outdent, .indent, .heading, .bold, .italic,
        .inlineCode, .codeBlock,
    ]

    /// Defaults an earlier build shipped, as stored ids. A saved layout identical to one of them
    /// was the default rather than a choice, so it reads as the current default; the web does the
    /// same (`toolbarConfig.ts`'s `PREVIOUS_DEFAULT_LAYOUTS`).
    private static let previousDefaultLayouts: [[String]] = [
        ["undo", "redo", "attach", "bulletList", "checkbox", "outdent", "indent", "heading"]
    ]

    /// Turns whatever was read back from storage into a safe layout. Total, the way the web's
    /// `loadToolbarLayout` is: a raw id this build does not recognise — an action a newer build
    /// added, or one an older build removed — is dropped rather than crashing or resetting
    /// anything else in the arrangement; a duplicate collapses to its first occurrence; and an
    /// empty result, whether nothing was ever stored or every stored id was unrecognised, falls
    /// back to ``defaultLayout`` rather than leaving the bar with nothing on it. Never silently
    /// invents a removed action back into existence — an unrecognised id simply isn't in the
    /// result.
    public static func sanitize(rawIds: [String]) -> [NoteToolbarActionId] {
        var seen = Set<NoteToolbarActionId>()
        var result: [NoteToolbarActionId] = []
        for raw in rawIds {
            guard let id = NoteToolbarActionId(rawValue: raw), !seen.contains(id) else { continue }
            seen.insert(id)
            result.append(id)
        }
        if result.isEmpty { return defaultLayout }
        return previousDefaultLayouts.contains(result.map(\.rawValue)) ? defaultLayout : result
    }
}
