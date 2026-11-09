import Foundation

/// A file an assistant reply shows: a line that is exactly `pai-file: /absolute/path`, written on
/// its own line to put a file the agent made (a screenshot, a diagram) in front of the reader. The
/// line is cut out of the text and the file is drawn where the line stood. Inside a fenced code
/// block the line is code and stays text, so a reply can show the marker itself. The grammar is the
/// web's `utils/fileMarkers.ts` and the backend's `extract_file_markers`; the backend's
/// `_resolve_marker_path` decides whether a file may be fetched at all.
public enum FileMarkers {

    /// One piece of a reply cut at its file markers.
    public enum Segment: Equatable, Sendable {
        case markdown(String)
        case file(String)
    }

    /// The reply cut at its file markers: the text between them and the paths they name, in
    /// order. A chunk that is only whitespace is dropped; text without a marker is one segment.
    /// Every marker line is its own segment, a path named twice drawing twice.
    public static func split(_ text: String) -> [Segment] {
        guard text.contains(prefix) else { return [.markdown(text)] }
        var segments: [Segment] = []
        var chunk: [Substring] = []
        var fence: (character: Character, length: Int)?

        func flush() {
            let joined = chunk.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                segments.append(.markdown(joined))
            }
            chunk = []
        }

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if let open = fence {
                if MarkdownFence.closes(line, character: open.character, length: open.length) { fence = nil }
                chunk.append(line)
                continue
            }
            if let opened = MarkdownFence.opening(line) {
                fence = opened
                chunk.append(line)
                continue
            }
            if let path = path(ofLine: line) {
                flush()
                segments.append(.file(path))
                continue
            }
            chunk.append(line)
        }
        flush()
        return segments
    }

    private static let prefix = "pai-file: "

    /// The path of a marker line: `pai-file: ` at the start of the line, then an absolute path
    /// whose first character after the slash is not whitespace, trailing whitespace dropped.
    private static func path(ofLine line: Substring) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        let rest = line.dropFirst(prefix.count)
        guard rest.first == "/", let second = rest.dropFirst().first, !second.isWhitespace else { return nil }
        return String(rest).trimmingCharacters(in: .whitespaces)
    }
}
