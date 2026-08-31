import Foundation

/// A note's summary is one line of YAML frontmatter — collapses any newline (Return in a growing
/// multi-line field, a paste) to a space, mirroring the collapse the backend's frontmatter writer
/// already applies server-side (`format_yaml_scalar`) so a client showing the summary while it is
/// being edited never disagrees with what actually gets stored. `Character.isNewline` treats a
/// `\r\n` pair as the single newline it is, rather than leaving a stray `\r` behind.
public func flattenNoteSummaryLine(_ text: String) -> String {
    var result = ""
    result.reserveCapacity(text.count)
    for character in text {
        result.append(character.isNewline ? " " : character)
    }
    return result
}
