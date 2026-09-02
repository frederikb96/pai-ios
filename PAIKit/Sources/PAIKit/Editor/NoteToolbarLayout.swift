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
    case heading, bold, italic, bulletList, checkbox, outdent, indent, inlineCode, quote, link

    /// The markdown command this action drives, or `nil` for the three that are not one:
    /// undo/redo delegate to the text view's own undo manager, and attach opens a file picker.
    public var command: MarkdownCommand? { MarkdownCommand(rawValue: rawValue) }

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

    /// Every action, in the order the settings screen lists a disabled one — the web's own
    /// tap-order comment in `NoteEditorKeyboardBar` before this became configurable.
    public static let allActionsInDefaultOrder: [NoteToolbarActionId] = [
        .undo, .redo, .attach,
        .heading, .bold, .italic, .bulletList, .checkbox, .outdent, .indent, .inlineCode, .quote, .link,
    ]

    /// Matches the web editor's own default (`toolbarConfig.ts`'s `DEFAULT_TOOLBAR_LAYOUT`):
    /// undo, redo, attach, bullet, checkbox, outdent, indent, heading — every one of which this
    /// editor already has an equivalent action for. Freddy's own chosen order there, not a set
    /// this file should grow on its own.
    public static let defaultLayout: [NoteToolbarActionId] = [
        .undo, .redo, .attach, .bulletList, .checkbox, .outdent, .indent, .heading,
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
        return result.isEmpty ? defaultLayout : result
    }
}
