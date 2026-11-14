import Foundation

/// The name this install sends as `X-Device-Name` on every request, so the server's list of
/// signed-in devices can tell one phone from another.
public enum DeviceName {
    public static let headerField = "X-Device-Name"

    /// The most characters the server accepts.
    public static let maxLength = 64

    /// What goes in the header for `name`: control characters (a line break would split the
    /// header) turned into spaces, surrounding whitespace dropped, cut to `maxLength` characters
    /// (never mid-character), and a name that is empty after that replaced by a generic one
    /// rather than sending an empty header.
    public static func header(for name: String) -> String {
        let printable = String(
            String.UnicodeScalarView(
                name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        let trimmed = printable.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "iPhone" }
        return String(trimmed.prefix(maxLength))
    }
}
