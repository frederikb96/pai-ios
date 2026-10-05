import Foundation

/// How a note's `last_write_source` and a revision's `source` are put to the owner. The values
/// are the backend's `NoteWriteSource` (`ui`, `disk`, `mcp`, `rename`, `restore`, `share`); one
/// the app does not know is shown as it came, never mapped to a guess.
public enum NoteWriteSource {

    /// "Last change from …" on the note's info tab.
    public static func infoLabel(_ source: String) -> String {
        switch source {
        case "ui": return "this app"
        case "disk": return "the synced folder on disk"
        case "mcp": return "an MCP tool call"
        case "rename": return "a link rewrite from renaming something else"
        case "restore": return "restoring a previous version"
        case "share": return "a visitor through a share link"
        default: return source
        }
    }

    /// The second line of a history row.
    public static func historyLabel(_ source: String) -> String {
        switch source {
        case "ui": return "edited here"
        case "disk": return "edited on disk"
        case "mcp": return "edited by MCP"
        case "rename": return "link rewrite"
        case "restore": return "restored"
        case "share": return "edited through a share link"
        default: return source
        }
    }
}
