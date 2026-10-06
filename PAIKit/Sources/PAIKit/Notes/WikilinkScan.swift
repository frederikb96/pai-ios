import Foundation

/// Linear-time scanners for the three things a wikilink scan needs from a note body: wikilinks,
/// code ranges, and a membership test over those ranges.
///
/// A note body can be text someone else wrote (a shared note with an edit link), so the scan
/// must stay linear in the body whatever it says. The patterns these replace —
/// `(!)?\[\[([^\]|#\n]+)(#[^\]|\n]+)?(\|[^\]\n]+)?\]\]` and `(`+)([^`\n]*?)\1` — restart at every
/// bracket or backtick and reread the rest of the body, which is quadratic on a body that is
/// mostly `[`. Each scanner here reads every character a bounded number of times, and
/// `NoteWikilinkScanTests` holds each to the pattern it stands in for.
///
/// Everything works on `[Character]`, the unit Swift's `Regex` matches over, so a grapheme
/// cluster such as `[` followed by a combining mark is one character that is not `[` — in the
/// scanner exactly as in the pattern. Offsets are Character offsets, as everywhere else in
/// `Notes/`. Mirrors `scanWikilinks` / `inlineSpanRanges` in `pai-cloud/web/src/apps/notes/
/// wikilinks.ts`; keep them in agreement.
enum WikilinkScan {
    /// One wikilink: offsets of the whole link and of each part that took part. `anchor` and
    /// `alias` include their leading `#` / `|`.
    struct Match: Equatable {
        let start: Int
        let end: Int
        let isEmbed: Bool
        let target: Range<Int>
        let anchor: Range<Int>?
        let alias: Range<Int>?
    }

    /// The first index at or after a position holding a character of a set, or `nil`. Remembers
    /// its last answer, so a scan whose questions only move forward reads each character once in
    /// total — what keeps every scanner here linear.
    private struct NextOf {
        let text: [Character]
        let stops: Set<Character>
        private var asked = -1
        private var answer: Int?

        init(_ text: [Character], stops: Set<Character>) {
            self.text = text
            self.stops = stops
        }

        mutating func find(_ pos: Int) -> Int? {
            if asked != -1, asked <= pos, answer == nil || pos <= answer! { return answer }
            var i = pos
            while i < text.count, !stops.contains(text[i]) { i += 1 }
            asked = pos
            answer = i < text.count ? i : nil
            return answer
        }
    }

    /// Wikilinks in `text`, in document order: what `matches(of:)` over the wikilink pattern
    /// finds. Every element of the pattern stops at the first character outside its class, and no
    /// shorter choice can be followed by what comes next, so each match is decided by where the
    /// next stop character lies.
    static func wikilinks(in text: [Character]) -> [Match] {
        var out: [Match] = []
        let n = text.count
        var targetStop = NextOf(text, stops: ["]", "|", "#", "\n"])
        var anchorStop = NextOf(text, stops: ["]", "|", "\n"])
        var aliasStop = NextOf(text, stops: ["]", "\n"])
        var pos = 0
        while true {
            guard let i = nextDoubleBracket(text, from: pos) else { return out }
            let t1 = targetStop.find(i + 2) ?? n
            var k = t1
            var anchor: Range<Int>?
            var alias: Range<Int>?
            var ok = t1 > i + 2
            if ok, k < n, text[k] == "#" {
                let a1 = anchorStop.find(k + 1) ?? n
                if a1 > k + 1 {
                    anchor = k..<a1
                    k = a1
                } else {
                    ok = false
                }
            }
            if ok, k < n, text[k] == "|" {
                let l1 = aliasStop.find(k + 1) ?? n
                if l1 > k + 1 {
                    alias = k..<l1
                    k = l1
                } else {
                    ok = false
                }
            }
            guard ok, k + 1 < n, text[k] == "]", text[k + 1] == "]" else {
                // Every later start before the stop this one failed at fails too: no `]` or
                // newline lies between, so each runs on to the same stop, and none can start on
                // the stop itself.
                pos = max(i + 1, ok ? k : t1)
                continue
            }
            let isEmbed = i - 1 >= pos && text[i - 1] == "!"
            out.append(
                Match(
                    start: isEmbed ? i - 1 : i, end: k + 2, isEmbed: isEmbed, target: (i + 2)..<t1,
                    anchor: anchor, alias: alias))
            pos = k + 2
        }
    }

    private static func nextDoubleBracket(_ text: [Character], from pos: Int) -> Int? {
        var i = pos
        while i + 1 < text.count {
            if text[i] == "[", text[i + 1] == "[" { return i }
            i += 1
        }
        return nil
    }

    /// Inline code spans: what `matches(of:)` over `(`+)([^`\n]*?)\1` finds. A run of `L`
    /// backticks first tries to close at the next backtick or newline on its line, which closes
    /// it only if a backtick run of at least `L` starts there; failing that, the engine settles
    /// on half the run (rounded down to even) as an empty span when `L >= 2`, or moves one
    /// character on.
    static func inlineSpans(in text: [Character]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var stop = NextOf(text, stops: ["`", "\n"])
        var pos = 0
        while true {
            var p = pos
            while p < text.count, text[p] != "`" { p += 1 }
            if p >= text.count { return out }
            var r = p
            while r < text.count, text[r] == "`" { r += 1 }
            let run = r - p
            if let q = stop.find(r), closes(text, at: q, run: run) {
                out.append(p..<(q + run))
                pos = q + run
            } else if run >= 2 {
                let half = 2 * (run / 2)
                out.append(p..<(p + half))
                pos = p + half
            } else {
                pos = p + 1
            }
        }
    }

    private static func closes(_ text: [Character], at q: Int, run: Int) -> Bool {
        guard q + run <= text.count else { return false }
        for i in q..<(q + run) where text[i] != "`" { return false }
        return true
    }

    /// Fenced code blocks, then inline code spans. A closing fence needs the same character and
    /// at least the same length as its opener (CommonMark); a fence line is up to three spaces or
    /// tabs, then a run of at least three backticks or tildes.
    static func codeRanges(in text: [Character]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var openFence: (char: Character, len: Int, start: Int)?
        var lineStart = 0
        while lineStart <= text.count {
            var lineEnd = lineStart
            while lineEnd < text.count, text[lineEnd] != "\n" { lineEnd += 1 }
            let hasNewline = lineEnd < text.count
            if let (char, len) = fenceRun(text, lineStart: lineStart, lineEnd: lineEnd) {
                if let open = openFence {
                    if char == open.char, len >= open.len {
                        ranges.append(open.start..<(hasNewline ? lineEnd + 1 : lineEnd))
                        openFence = nil
                    }
                } else {
                    openFence = (char, len, lineStart)
                }
            }
            if !hasNewline { break }
            lineStart = lineEnd + 1
        }
        if let open = openFence { ranges.append(open.start..<text.count) }
        ranges.append(contentsOf: inlineSpans(in: text))
        return ranges
    }

    /// The fence character and run length at the start of a line, if it opens one.
    private static func fenceRun(_ text: [Character], lineStart: Int, lineEnd: Int) -> (Character, Int)? {
        var i = lineStart
        while i < lineEnd, i - lineStart < 3, text[i] == " " || text[i] == "\t" { i += 1 }
        guard i < lineEnd, text[i] == "`" || text[i] == "~" else { return nil }
        let char = text[i]
        var j = i
        while j < lineEnd, text[j] == char { j += 1 }
        return j - i >= 3 ? (char, j - i) : nil
    }

    /// Membership in a union of half-open ranges, by binary search over the merged ranges.
    struct Excluded {
        private var starts: [Int] = []
        private var ends: [Int] = []

        init(_ ranges: [Range<Int>]) {
            for range in ranges.sorted(by: { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }) {
                if let last = ends.last, range.lowerBound <= last {
                    ends[ends.count - 1] = max(last, range.upperBound)
                } else {
                    starts.append(range.lowerBound)
                    ends.append(range.upperBound)
                }
            }
        }

        func contains(_ pos: Int) -> Bool {
            var lo = 0
            var hi = starts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if starts[mid] <= pos { lo = mid + 1 } else { hi = mid }
            }
            return lo > 0 && pos < ends[lo - 1]
        }
    }
}
