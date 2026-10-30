import Foundation

/// Words Claude Code reads in a prompt as an instruction to itself (`ultrathink` raises the
/// turn's reasoning, `ultracode` asks for a workflow), found the way its own keyword detector
/// finds them, so a word listed here is one the client treats as asked for.
///
/// A keyword is a whole word in any case (ASCII letters, digits and `_` make a word, as in the
/// client's JavaScript). Nothing counts when the text starts with `/`; a word inside a quoted or
/// bracketed span (`"…"`, `'…'`, backticks, `[…]`, `{…}`, `(…)`, `<tag>…</tag>`) is quoted rather
/// than asked for; and one glued to a path or a hyphenated term is not a word of its own. The
/// web composer (`utils/promptKeywords.ts`) answers the same; the case table in
/// `Resources/prompt-keywords.json` binds the two, and a test holds `keywords` to that file's
/// list. Offsets are UTF-16 code units, as `UITextView` counts them.
public enum PromptKeywords {
    public struct Match: Equatable, Sendable {
        /// The keyword as listed, lowercase, whatever case the text has it in.
        public let word: String
        public let range: NSRange
    }

    static let keywords = ["ultrathink", "ultracode"]

    private static let keywordUnits: [(word: String, units: [UInt16])] = keywords.map { ($0, Array($0.utf16)) }

    private static let closer: [UInt16: UInt16] = [
        0x60: 0x60,  // `
        0x22: 0x22,  // "
        0x3C: 0x3E,  // < >
        0x7B: 0x7D,  // { }
        0x5B: 0x5D,  // [ ]
        0x28: 0x29,  // ( )
        0x27: 0x27,  // '
    ]
    private static let slash: UInt16 = 0x2F
    private static let backslash: UInt16 = 0x5C
    private static let hyphen: UInt16 = 0x2D
    private static let questionMark: UInt16 = 0x3F
    private static let fullStop: UInt16 = 0x2E
    private static let apostrophe: UInt16 = 0x27
    private static let angleOpen: UInt16 = 0x3C
    private static let squareOpen: UInt16 = 0x5B

    /// Every keyword occurrence in the text that Claude Code would act on, in order.
    public static func find(in text: String) -> [Match] {
        let units = Array(text.utf16)
        guard units.first != slash else { return [] }
        let spans = quotedSpans(in: units)
        var found: [Match] = []
        var index = 0
        // Matches come in increasing order and spans never overlap, so one cursor walks both.
        var spanCursor = 0
        while index < units.count {
            guard let (word, length) = keyword(at: index, in: units) else {
                index += 1
                continue
            }
            let end = index + length
            defer { index = end }
            while spanCursor < spans.count, spans[spanCursor].upperBound <= index { spanCursor += 1 }
            if spanCursor < spans.count, spans[spanCursor].lowerBound <= index { continue }
            if index > 0, [slash, backslash, hyphen].contains(units[index - 1]) { continue }
            if end < units.count {
                let after = units[end]
                if [slash, backslash, hyphen, questionMark].contains(after) { continue }
                if after == fullStop, end + 1 < units.count, isWordCharacter(units[end + 1]) { continue }
            }
            found.append(Match(word: word, range: NSRange(location: index, length: length)))
        }
        return found
    }

    /// Each keyword the text names, once, in the order it first appears.
    public static func words(in text: String) -> [String] {
        var seen = Set<String>()
        return find(in: text).map(\.word).filter { seen.insert($0).inserted }
    }

    /// The listed keyword that spells a whole ASCII word at `index`, compared without case.
    private static func keyword(at index: Int, in units: [UInt16]) -> (String, Int)? {
        guard index == 0 || !isAsciiWord(units[index - 1]) else { return nil }
        for (word, candidate) in keywordUnits {
            let end = index + candidate.count
            guard end <= units.count else { continue }
            let spelled = (0..<candidate.count).allSatisfy { lowercased(units[index + $0]) == candidate[$0] }
            if spelled, end == units.count || !isAsciiWord(units[end]) { return (word, candidate.count) }
        }
        return nil
    }

    /// `[start, end)` of every span the text quotes.
    private static func quotedSpans(in units: [UInt16]) -> [Range<Int>] {
        var spans: [Range<Int>] = []
        var open: UInt16?
        var spanStart = 0
        for i in units.indices {
            let unit = units[i]
            if let opener = open {
                if opener == squareOpen, unit == squareOpen {
                    spanStart = i
                    continue
                }
                guard unit == closer[opener] else { continue }
                if opener == apostrophe, i + 1 < units.count, isWordCharacter(units[i + 1]) { continue }
                spans.append(spanStart..<(i + 1))
                open = nil
            } else if unit == angleOpen {
                if i + 1 < units.count, isAsciiLetter(units[i + 1]) || units[i + 1] == slash {
                    open = unit
                    spanStart = i
                }
            } else if unit == apostrophe {
                if i == 0 || !isWordCharacter(units[i - 1]) {
                    open = unit
                    spanStart = i
                }
            } else if closer[unit] != nil {
                open = unit
                spanStart = i
            }
        }
        return spans
    }

    private static func lowercased(_ unit: UInt16) -> UInt16 {
        (0x41...0x5A).contains(unit) ? unit + 0x20 : unit
    }

    private static func isAsciiLetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    private static func isAsciiWord(_ unit: UInt16) -> Bool {
        isAsciiLetter(unit) || (0x30...0x39).contains(unit) || unit == 0x5F
    }

    /// A letter, number or `_`. A surrogate half is never one: the client reads UTF-16 units one
    /// at a time, so a character outside the BMP does not count either.
    private static func isWordCharacter(_ unit: UInt16) -> Bool {
        if unit == 0x5F { return true }
        guard let scalar = Unicode.Scalar(unit) else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }
}
