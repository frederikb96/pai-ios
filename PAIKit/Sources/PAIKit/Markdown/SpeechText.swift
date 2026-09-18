import Foundation

/// Renders parsed markdown into text a TTS engine should read aloud, rather than into text a
/// screen should show — the two diverge exactly where a block carries no linear reading, which is
/// why this sits beside `MarkdownBlock` instead of reusing `plainText`. Most of the syntax
/// stripping `plainText` already does (emphasis markers, a link's own URL) is inherited for free:
/// this only changes shape where markup would otherwise be read as noise or as silence.
///
/// Never truncates and never drops a block silently — a code block or a table is announced by
/// what it is rather than being skipped, because losing a stretch of a reply without saying so is
/// the one failure Freddy asked this feature never to have.
public enum SpeechText {

    /// The full spoken form of a reply: one sentence-terminated phrase per block, joined with a
    /// space so a TTS engine's own prosody supplies the pause between them.
    public static func speakable(_ blocks: [MarkdownBlock]) -> String {
        blocks.map(speakable(block:))
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Splits already-speakable text into sentence-sized pieces for `SendTextMulti` frames —
    /// sent incrementally so "computer skip" can interrupt within a reply rather than only
    /// between replies, and so a TTS socket drop mid-reply costs only the sentence in flight
    /// rather than the whole thing. Not linguistically exact; a sentence boundary is whatever
    /// immediately follows `.`, `!` or `?`, which is good enough for interruption granularity.
    public static func sentences(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if ".!?".contains(character) {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
                current = ""
            }
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { result.append(trailing) }
        return result
    }

    private static func speakable(block: MarkdownBlock) -> String {
        switch block {
        case .paragraph(let text), .heading(_, let text):
            return sentence(stripEmoji(text.plainText))

        case .preformattedText(let text):
            // Unlike `.codeBlock`, this is Claude's own reasoning, not code — reading the words
            // aloud is the honest answer, the same treatment a paragraph gets.
            return sentence(stripEmoji(text))

        case .codeBlock(let language, let code):
            let lineCount = code.split(separator: "\n", omittingEmptySubsequences: false).count
            let languagePart = language.map { ", \($0)" } ?? ""
            return "Code block\(languagePart), \(lineCount) \(pluralize("line", lineCount))."

        case .blockQuote(let blocks):
            return speakable(blocks)

        case .list(let list):
            // Bullets and item numbers are dropped rather than spoken — the design's own call —
            // so a list reads as ordinary flowing prose, one item after another.
            return list.items
                .map { speakable($0.blocks) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

        case .table(let table):
            let rowCount = table.rows.count
            let columnCount = table.columnCount
            return
                "Table, \(rowCount) \(pluralize("row", rowCount)), \(columnCount) \(pluralize("column", columnCount))."

        case .thematicBreak:
            // A rule is a border, not content — nothing was said here for the reply to be
            // missing, matching `MarkdownBlock.plainText`'s own reasoning for the same case.
            return ""

        case .htmlBlock(let raw):
            let lineCount = raw.split(separator: "\n", omittingEmptySubsequences: false).count
            return "HTML block, \(lineCount) \(pluralize("line", lineCount))."
        }
    }

    private static func pluralize(_ word: String, _ count: Int) -> String {
        count == 1 ? word : "\(word)s"
    }

    /// Ensures a block ends on sentence-terminating punctuation, so a TTS engine pauses between
    /// blocks the way it would between sentences, and collapses whatever whitespace stripping an
    /// emoji left behind into single spaces.
    private static func sentence(_ text: String) -> String {
        let collapsed =
            text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return "" }
        if let last = collapsed.last, ".!?:;".contains(last) { return collapsed }
        return collapsed + "."
    }

    /// The scalar ranges emoji actually live in, deliberately narrow: ASCII digits, `#` and `*`
    /// report `Unicode.Scalar.Properties.isEmoji == true` too (they participate in keycap
    /// sequences like 1️⃣), so filtering on that property alone would strip plain numbers out of
    /// a reply that says "$0.39/hour". Named ranges avoid that trap entirely.
    private static let emojiRanges: [ClosedRange<UInt32>] = [
        0x2600...0x27BF,  // Misc symbols, dingbats
        0x1F300...0x1FAFF,  // Misc symbols & pictographs, emoticons, transport, supplemental symbols
        0x1F1E6...0x1F1FF,  // Regional indicator letters (flag pairs)
    ]

    /// A judgement call rather than a settled decision: a decorative glyph read aloud mid-sentence
    /// ("rotating light") is worse than silently dropping it, so every recognised emoji is
    /// stripped rather than spelled out.
    private static func stripEmoji(_ text: String) -> String {
        String(
            text.unicodeScalars.filter { scalar in
                // U+FE0F (variation selector-16) and U+200D (zero-width joiner) never carry
                // their own reading and only ever ride alongside an emoji this already strips.
                if scalar.value == 0xFE0F || scalar.value == 0x200D { return false }
                return !emojiRanges.contains { $0.contains(scalar.value) }
            })
    }
}
