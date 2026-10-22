import Foundation

/// Which `/name` tokens in a message Claude Code will treat as skills.
///
/// The rules are Claude Code's own: a token is a slash, a letter, then letters, digits and
/// `.:-_`, with trailing dots cut off, and it counts only with whitespace or the edge of the text
/// on both sides — so `/dummy,` and `/tmp/x` never do. When the message starts with a slash, the
/// leading run of tokens separated by nothing but whitespace is the invocation chain: those run,
/// everything later is a mention, which Claude Code reads as permission to use that skill.
///
/// Only names from the session's own listing count, so a typo is visible here exactly when Claude
/// Code would ignore it. The web composer (`utils/skillMentions.ts`) answers the same; the case
/// table in `Resources/skill-mention-cases.json` binds the two. Offsets are UTF-16 code units, as
/// `UITextView` counts them.
public enum SkillMentions {
    public enum Kind: String, Sendable {
        case runs
        case mention
        case nearMiss
    }

    public struct Mention: Equatable, Sendable {
        public let kind: Kind
        /// The name as typed, without the slash.
        public let token: String
        /// The skill it names — for a near miss, the one it was probably meant to be.
        public let name: String
        /// Where the token sits, slash included.
        public let range: NSRange
    }

    public struct Completion: Equatable, Sendable {
        /// The partial token at the caret, slash included.
        public let range: NSRange
        public let candidates: [String]
    }

    /// Unknown tokens looked at for a near miss; past this a pasted wall of slashes costs nothing
    /// more.
    static let nearMissScanLimit = 32
    static let maxCandidates = 6

    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"(^|[\s\x{3002}\x{3001}\x{FF1F}\x{FF01}])(/[a-zA-Z][a-zA-Z0-9.:\-_]*)"#)

    /// Every skill the text names, in order, each name once.
    public static func find(in text: String, names: [String]) -> [Mention] {
        let source = text as NSString
        let known = Set(names)
        var result: [Mention] = []
        var seen = Set<String>()
        var inChain = text.hasPrefix("/")
        var chainEnd = 0
        var unknownScanned = 0
        for range in tokens(in: source) {
            let gap = source.substring(with: NSRange(location: chainEnd, length: range.location - chainEnd))
            let runs = inChain && gap.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if runs { chainEnd = NSMaxRange(range) } else { inChain = false }
            guard isBounded(source, range) else { continue }
            let token = source.substring(with: NSRange(location: range.location + 1, length: range.length - 1))
            if known.contains(token) {
                guard seen.insert(token).inserted else { continue }
                result.append(Mention(kind: runs ? .runs : .mention, token: token, name: token, range: range))
                continue
            }
            guard unknownScanned < nearMissScanLimit, seen.insert("?" + token).inserted else { continue }
            unknownScanned += 1
            if let name = nearestName(token, names: names) {
                result.append(Mention(kind: .nearMiss, token: token, name: name, range: range))
            }
        }
        return result
    }

    /// The names a partial `/token` ending at the caret could complete to: prefix matches on the
    /// full name, or on a plugin skill's bare name.
    public static func completion(in text: String, caret: Int, names: [String]) -> Completion? {
        let source = text as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        if caret < source.length, !isWhitespace(source.character(at: caret)) { return nil }
        var slash = caret - 1
        while slash >= 0, isTokenCharacter(source.character(at: slash)) { slash -= 1 }
        guard slash >= 0, source.character(at: slash) == UInt16(UInt8(ascii: "/")) else { return nil }
        if slash > 0, !isWhitespace(source.character(at: slash - 1)) { return nil }
        let prefix = source.substring(with: NSRange(location: slash + 1, length: caret - slash - 1))
        guard let first = prefix.unicodeScalars.first, isAsciiLetter(first) else { return nil }
        let matching = names.filter { name in
            guard name != prefix else { return false }
            let bare = name.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? name
            return name.hasPrefix(prefix) || bare.hasPrefix(prefix)
        }
        let candidates = Array(
            matching.sorted { $0.utf16.count != $1.utf16.count ? $0.utf16.count < $1.utf16.count : $0 < $1 }
                .prefix(maxCandidates))
        guard !candidates.isEmpty else { return nil }
        return Completion(range: NSRange(location: slash, length: caret - slash), candidates: candidates)
    }

    /// The text with `range` replaced by `/name`, followed by one space — an existing one is
    /// stepped over, not doubled. The caret (UTF-16) goes after it.
    public static func replace(_ range: NSRange, in text: String, with name: String) -> (text: String, caret: Int) {
        let source = text as NSString
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        let token = "/" + name
        let end = range.location + (token as NSString).length
        if after.hasPrefix(" ") { return (before + token + after, end + 1) }
        if let first = after.utf16.first, isWhitespace(first) { return (before + token + after, end) }
        return (before + token + " " + after, end + 1)
    }

    private static func tokens(in source: NSString) -> [NSRange] {
        tokenPattern.matches(in: source as String, range: NSRange(location: 0, length: source.length)).map {
            var token = $0.range(at: 2)
            while token.length > 0, source.character(at: NSMaxRange(token) - 1) == UInt16(UInt8(ascii: ".")) {
                token.length -= 1
            }
            return token
        }
    }

    private static func isBounded(_ source: NSString, _ range: NSRange) -> Bool {
        let end = NSMaxRange(range)
        return (range.location == 0 || isWhitespace(source.character(at: range.location - 1)))
            && (end == source.length || isWhitespace(source.character(at: end)))
    }

    /// JavaScript's `\s` over one UTF-16 unit — the class Claude Code tests against.
    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isWhitespace || unit == 0xFEFF
    }

    private static func isTokenCharacter(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return isAsciiLetter(scalar) || ("0"..."9").contains(scalar) || ".:-_".unicodeScalars.contains(scalar)
    }

    private static func isAsciiLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// The skill an unknown token most likely meant: one edit for a name of up to six letters,
    /// two for a longer one, nothing under three. Ties go to the alphabetically first name.
    private static func nearestName(_ token: String, names: [String]) -> String? {
        let typed = Array(token.utf16)
        guard typed.count >= 3 else { return nil }
        let limit = typed.count <= 6 ? 1 : 2
        var best: String?
        var bestDistance = limit + 1
        for name in names {
            let distance = distance(typed, Array(name.utf16), within: limit)
            if distance < bestDistance || (distance == bestDistance && best.map { name < $0 } == true) {
                best = name
                bestDistance = distance
            }
        }
        return bestDistance <= limit ? best : nil
    }

    /// Edit distance, or `limit + 1` as soon as it is certain to exceed `limit`.
    private static func distance(_ a: [UInt16], _ b: [UInt16], within limit: Int) -> Int {
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            var rowMin = i
            for j in stride(from: 1, through: b.count, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            previous = current
        }
        return previous[b.count]
    }
}
