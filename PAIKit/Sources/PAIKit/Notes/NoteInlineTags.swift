import Foundation

/// The inline `#tags` of a note's prose, found in the text the read view draws.
///
/// The grammar is the one the server uses to build each note's tag list (what the tag filter
/// offers), and the web's read view draws chips by the same rule, so a word is drawn as a tag
/// exactly when the filter lists it: a `#` that opens a line or follows whitespace, then letters,
/// digits, `_`, `/` and `-`. A trailing `-` or `/` is punctuation and stays out of the tag, and a
/// tag of digits and separators only (`#1`, `#2026`) is numbering. Code, links and formulas are
/// never scanned.
public enum NoteInlineTags {
    public enum Piece: Equatable, Sendable {
        case text(String)
        /// A tag, without its `#`.
        case tag(String)
    }

    /// The scheme of the link a drawn tag carries, followed by the percent-encoded tag.
    public static let urlScheme = "pai-tag"

    /// `text` cut into plain stretches and tags. `previous` is the character just ahead of the
    /// text (`nil` at the start of a block), which a `#` at the very start is judged against.
    public static func pieces(in text: String, after previous: Character? = nil) -> [Piece] {
        let scalars = Array(text.unicodeScalars)
        var pieces: [Piece] = []
        var cursor = 0  // start of the plain text not yet emitted
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "#", opensTag(at: i, in: scalars, after: previous) else {
                i += 1
                continue
            }
            var end = i + 1
            while end < scalars.count, isTagScalar(scalars[end]) { end += 1 }
            guard end > i + 1 else {
                i += 1
                continue
            }
            var name = Array(scalars[(i + 1)..<end])
            while let last = name.last, last == "-" || last == "/" { name.removeLast() }
            if !name.isEmpty, name.contains(where: hasLetterRole) {
                if i > cursor { pieces.append(.text(string(scalars[cursor..<i]))) }
                pieces.append(.tag(string(name[...])))
                cursor = i + 1 + name.count
            }
            // The match is consumed whole, trailing separators included: a `#` right after
            // them is glued to a non-space character and is not a tag.
            i = end
        }
        guard !pieces.isEmpty else { return [] }
        if cursor < scalars.count { pieces.append(.text(string(scalars[cursor...]))) }
        return pieces
    }

    /// `text` with every tag in its plain runs split out as a run of its own, styled ``InlineStyle/noteTag``
    /// and carrying ``url(for:)``. Runs that are code, formulas or links are left alone, but still
    /// count as the character ahead of the next run, so `**b**#x` is not a tag.
    public static func tagged(_ text: InlineText) -> InlineText {
        var runs: [InlineRun] = []
        var previous: Character?
        var changed = false
        for run in text.runs {
            defer { if let last = run.text.last { previous = last } }
            guard run.destination == nil, !run.style.contains(.code), !run.style.contains(.math),
                !run.style.contains(.noteTag)
            else {
                runs.append(run)
                continue
            }
            let found = pieces(in: run.text, after: previous)
            guard !found.isEmpty else {
                runs.append(run)
                continue
            }
            changed = true
            for piece in found {
                switch piece {
                case .text(let plain):
                    runs.append(InlineRun(text: plain, style: run.style))
                case .tag(let name):
                    runs.append(
                        InlineRun(
                            text: "#" + name, style: run.style.union(.noteTag), destination: url(for: name)))
                }
            }
        }
        return changed ? InlineText(runs: runs) : text
    }

    /// The link a drawn tag carries, read back with ``tag(from:)``.
    public static func url(for tag: String) -> String {
        urlScheme + ":" + (tag.addingPercentEncoding(withAllowedCharacters: unreserved) ?? tag)
    }

    /// The tag a link written by ``url(for:)`` names; `nil` for any other URL.
    public static func tag(from url: URL) -> String? {
        let prefix = urlScheme + ":"
        let text = url.absoluteString
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let name = String(text.dropFirst(prefix.count)).removingPercentEncoding
        return name.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    private static func opensTag(at index: Int, in scalars: [Unicode.Scalar], after previous: Character?) -> Bool {
        if index > 0 { return scalars[index - 1].properties.isWhitespace }
        guard let previous else { return true }
        return previous.isWhitespace
    }

    private static func isTagScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" || scalar == "/" || scalar == "-" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    /// What makes a tag more than numbering: a letter or an underscore.
    private static func hasLetterRole(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            return false
        }
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }
}
