import Foundation

/// A pasted image leaves a marker in the composer text where it was pasted, so the message can
/// say which screenshot it means at that point.
///
/// The marker and the file share a name: `[📎 paste-2]` in the text, a file uploaded as
/// `paste-2.png`. Nothing on the server knows about markers — the VM keeps the uploaded name
/// inside the path it lists under the message (`…-paste-2.png`), and that shared name is the whole
/// link. The web composer (`utils/pasteMarkers.ts`) writes the same markers, so a draft started on
/// one device numbers on correctly on the other.
public enum PasteMarkers {
    /// The number the next pasted image takes: one past the highest already in use, by a marker
    /// still in the text or by a file still attached. Removing either half alone therefore never
    /// hands its number to a new paste that a leftover marker or file would then share.
    public static func nextNumber(text: String, filenames: [String]) -> Int {
        var highest = 0
        for number in numbers(in: text, pattern: #"\[📎 paste-(\d+)\]"#) {
            highest = max(highest, number)
        }
        for name in filenames {
            for number in numbers(in: name, pattern: #"(?:^|-)paste-(\d+)\.[^.]*$"#) {
                highest = max(highest, number)
            }
        }
        return highest + 1
    }

    /// Names for a paste of several images, numbered on from what the draft already uses, and
    /// the markers for them as one string to put at the caret.
    public static func name(_ originals: [String], text: String, filenames: [String]) -> (
        filenames: [String], markers: String
    ) {
        let first = nextNumber(text: text, filenames: filenames)
        let numbers = originals.indices.map { first + $0 }
        return (
            zip(numbers, originals).map { filename($0, original: $1) },
            numbers.map(marker).joined(separator: " ")
        )
    }

    public static func marker(_ number: Int) -> String {
        "[📎 paste-\(number)]"
    }

    /// `paste-<n>` with the original's extension, so the type it is served back as is kept.
    public static func filename(_ number: Int, original: String) -> String {
        let ext = (original as NSString).pathExtension
        return ext.isEmpty ? "paste-\(number)" : "paste-\(number).\(ext)"
    }

    /// Put `insert` in place of `selection` (UTF-16 offsets, as `UITextView.selectedRange` gives
    /// them), with a space on either side unless the neighbour is already whitespace or the edge
    /// of the text — a marker must never fuse with the word it was pasted next to. Answers the new
    /// text and the UTF-16 offset the caret goes to: just past the insert.
    public static func insert(_ insert: String, into text: String, replacing selection: NSRange) -> (
        text: String, caret: Int
    ) {
        let planned = edit(insert, in: text, replacing: selection)
        let replaced = (text as NSString).replacingCharacters(in: planned.range, with: planned.replacement)
        return (replaced, planned.caret)
    }

    /// The same insertion as one edit — the clamped range to replace and what replaces it — for a
    /// text view that applies it through its own edit path, so undo keeps the typing before it.
    public static func edit(_ insert: String, in text: String, replacing selection: NSRange) -> (
        range: NSRange, replacement: String, caret: Int
    ) {
        let source = text as NSString
        let start = min(max(selection.location, 0), source.length)
        let end = min(start + max(selection.length, 0), source.length)
        let lead = start > 0 ? padding(beforeUnitAt: start - 1, in: source) : ""
        let trail = end < source.length ? padding(beforeUnitAt: end, in: source) : ""
        let caret = start + (lead as NSString).length + (insert as NSString).length
        return (NSRange(location: start, length: end - start), lead + insert + trail, caret)
    }

    /// A space unless the character containing the UTF-16 unit at `index` is whitespace.
    private static func padding(beforeUnitAt index: Int, in source: NSString) -> String {
        let character = source.substring(with: source.rangeOfComposedCharacterSequence(at: index))
        return (character.first?.isWhitespace ?? false) ? "" : " "
    }

    private static func numbers(in text: String, pattern: String) -> [Int] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap {
            Int(source.substring(with: $0.range(at: 1)))
        }
    }
}
