import Foundation

/// SwiftUI's `Text` has no supported way to break a run of non-whitespace characters mid-word the
/// way CSS `word-break: break-all` does — `NSParagraphStyle.lineBreakMode` is a UIKit attribute
/// `Text(AttributedString)` silently ignores, and ordinary word-wrapping only ever breaks between
/// words. The one shape that actually needs it in practice is a bare URL or filesystem path with
/// no spaces at all, long enough to overflow the transcript's own column width.
///
/// Inserting a zero-width space (`U+200B`) every `breakEvery` characters inside such a run gives
/// the platform's own word-wrapping algorithm somewhere to break — Unicode's line-breaking rules
/// treat U+200B as a break opportunity, so both TextKit's real measurement and SwiftUI's own
/// rendering honor it identically, with neither needing the paragraph-style support neither
/// actually has.
///
/// Confined to a run already longer than the threshold: ordinary prose, which is nearly all of
/// what a Thinking block actually contains, comes back character-for-character unchanged.
public enum LongTokenSoftBreaker {
    /// Chosen short enough to guarantee a break inside any column width the transcript ever lays
    /// out at on a phone, long enough that no ordinary English word crosses it.
    public static let breakEvery = 24

    private static let softBreak: Character = "\u{200B}"

    /// `text` with soft break points inserted, and where each one landed — every offset is a
    /// UTF-16 position in the ORIGINAL `text`, meaning "one character was inserted here." A
    /// caller holding ranges computed against the original text passes them through
    /// `remap(_:insertionOffsets:)` before applying them to this function's own `text` result.
    public static func apply(to text: String) -> (text: String, insertionOffsets: [Int]) {
        var result = ""
        result.reserveCapacity(text.count)
        var insertionOffsets: [Int] = []
        var runLength = 0
        var utf16Offset = 0
        for character in text {
            if character.isWhitespace {
                runLength = 0
                result.append(character)
                utf16Offset += String(character).utf16.count
                continue
            }
            result.append(character)
            utf16Offset += String(character).utf16.count
            runLength += 1
            if runLength == breakEvery {
                result.append(softBreak)
                insertionOffsets.append(utf16Offset)
                runLength = 0
            }
        }
        return (result, insertionOffsets)
    }

    /// Shifts a UTF-16 range computed against the text `apply(to:)` was given onto the string it
    /// returned. Every insertion at or before the range's start pushes it forward by one; one
    /// strictly inside it widens the range by one too, since a soft break splits what it lands on
    /// rather than replacing any of it — the highlight still needs to cover the same original
    /// characters, now on both sides of an invisible character.
    public static func remap(_ range: NSRange, insertionOffsets: [Int]) -> NSRange {
        guard !insertionOffsets.isEmpty else { return range }
        let before = insertionOffsets.filter { $0 <= range.location }.count
        let inside = insertionOffsets.filter { $0 > range.location && $0 < range.location + range.length }.count
        return NSRange(location: range.location + before, length: range.length + inside)
    }
}
