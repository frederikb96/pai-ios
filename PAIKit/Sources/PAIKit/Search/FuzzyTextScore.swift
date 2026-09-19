import Foundation

/// One word of a query, prepared once for a whole pass over a corpus.
///
/// Carries the word in both representations because both are needed and neither is derivable
/// cheaply: the `String` answers "does the field contain this", the `[Character]` is what the
/// edit-distance walk indexes into. Deriving either per candidate is what makes a filter feel
/// slow — measured, it is the single largest cost after folding.
public struct FuzzyQueryWord: Sendable {
    public let text: String
    public let chars: [Character]
    public let mask: UInt64
    /// How many edits this word tolerates: 0 below the fuzzy floor (literal or nothing), then
    /// widening once with length so a long word is not held to a budget that suits a short one.
    public let editBudget: Int

    public init(_ text: String) {
        self.text = text
        chars = Array(text)
        mask = FuzzyTextScore.characterMask(chars)
        if chars.count < FuzzyTextScore.minFuzzyWordLength {
            editBudget = 0
        } else {
            editBudget = chars.count <= 6 ? 1 : 2
        }
    }
}

/// One token of a candidate field, kept in the form the comparison actually needs.
public struct FuzzyToken: Sendable {
    public let chars: [Character]
    public let mask: UInt64

    public init(_ chars: [Character]) {
        self.chars = chars
        mask = FuzzyTextScore.characterMask(chars)
    }
}

/// A whole query, prepared once. Splitting and lowercasing per candidate is pure waste when
/// there are a thousand of them and one of it.
public struct FuzzyQuery: Sendable {
    public let normalized: String
    public let words: [FuzzyQueryWord]
    public var isEmpty: Bool { normalized.isEmpty }

    /// `normalized` must already be case- and diacritic-folded by the caller, the same way the
    /// fields it will be scored against are — folding on both sides is the only thing that makes
    /// "muller" find "Müller", and doing it here as well would fold twice.
    public init(normalized: String) {
        self.normalized = normalized
        words = FuzzyTextScore.words(normalized).map(FuzzyQueryWord.init)
    }
}

/// One field of one candidate, folded and tokenised ahead of time.
///
/// This is the half worth caching: a query changes on every keystroke and a corpus does not, so
/// everything here is computed once per note and reused for the whole time someone is typing.
public struct FuzzyField: Sendable {
    public let folded: String
    public let words: [FuzzyToken]

    /// `folded` is the already case- and diacritic-folded text.
    public init(folded: String) {
        self.folded = folded
        words = FuzzyTextScore.words(folded).map { FuzzyToken(Array($0)) }
    }
}

/// The scoring half of `pai-cloud/backend/src/pai_cloud/search.py` — the matcher the session
/// list already reads through, as a pure function so anything filtering an in-memory list can
/// behave the same way without a round trip.
///
/// Why a port rather than a call: the session list can afford a server query because its corpus
/// lives there and its debounce is a second long. A note filter cannot — the whole index is
/// already on the device, and a keystroke has to narrow the list within a frame. So the
/// behaviour is shared and the transport is not.
///
/// 🚨 This and `search.py` are one algorithm written twice. A change to either is a change to
/// both, and the tests on each side carry the same cases so a divergence is a red suite rather
/// than two clients that quietly disagree about what "matches".
public enum FuzzyTextScore {

    // Tiers, and the reason they are tiers rather than a single similarity number: an exact
    // name dominates everything, and a query that merely shares words with a long title must
    // never outrank one that is the title. Mirrors `search.py`'s own constants.
    static let exact = 1000.0
    static let prefix = 500.0
    static let substring = 200.0
    static let allWords = 100.0
    static let partialWordMax = 50.0
    /// A secondary field's own tiers — a bonus on top of a primary-field hit, or a weaker match
    /// of its own when nothing else hit. `search.py` spends these on a session's working
    /// directory; here they are what a note's summary is worth beside its name.
    static let secondarySubstring = 80.0
    static let secondaryWord = 20.0
    static let base = 50.0

    /// Below this length almost every word sits within one edit of almost every other, so
    /// tolerance would widen the result set on the first keystroke instead of narrowing it.
    /// Short words match literally or not at all.
    static let minFuzzyWordLength = 4

    /// Splits on anything that is not a letter or a digit, so `00_aTI`, `SSO-Rollout` and
    /// `a.b.c` all tokenise the way a reader would read them.
    ///
    /// Unicode-aware rather than `search.py`'s ASCII `[a-z0-9]+`: the input here is already
    /// diacritic-folded by the caller, but a vault holds names an ASCII class would shred into
    /// single letters, and a token per letter matches everything.
    public static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// How well `field` answers `query`. Zero means no match at all — the caller filters on that
    /// rather than on a threshold, so "matches" and "ranks well" stay one decision.
    public static func textScore(field: FuzzyField?, query: FuzzyQuery) -> Double {
        guard let field, !field.folded.isEmpty, !query.words.isEmpty else { return 0 }
        if field.folded == query.normalized { return exact }
        if field.folded.hasPrefix(query.normalized) { return prefix }
        if field.folded.contains(query.normalized) { return substring }
        let matched = matchedWordCount(field: field, query: query)
        if matched == 0 { return 0 }
        if matched == query.words.count { return allWords }
        return partialWordMax * (Double(matched) / Double(query.words.count))
    }

    /// The same shape one tier down, for a field that supports a match rather than being the
    /// thing being searched for.
    public static func secondaryScore(field: FuzzyField?, query: FuzzyQuery) -> Double {
        guard let field, !field.folded.isEmpty, !query.words.isEmpty else { return 0 }
        if field.folded.contains(query.normalized) { return secondarySubstring }
        return secondaryWord * Double(matchedWordCount(field: field, query: query))
    }

    private static func matchedWordCount(field: FuzzyField, query: FuzzyQuery) -> Int {
        var matched = 0
        for word in query.words where wordHit(word, in: field) { matched += 1 }
        return matched
    }

    /// Whether one query word appears in a field, tolerating a transposed or a missing character
    /// once the word is long enough for that not to be true of everything — a literal test alone
    /// misses "sesion" for "session".
    public static func wordHit(_ word: FuzzyQueryWord, in field: FuzzyField) -> Bool {
        // A query word holds no separators, and a token boundary is a separator, so a literal
        // hit anywhere in the field is a literal hit inside one token — one search over the
        // whole string rather than one per token.
        if field.folded.contains(word.text) { return true }
        guard word.editBudget > 0 else { return false }
        for token in field.words {
            // Every distinct character the query word has and the token lacks costs at least one
            // edit, so a popcount rejects the overwhelming majority of pairs in two instructions
            // instead of a dynamic-programming walk. It only ever rejects pairs the walk would
            // also have rejected — see `characterMask`.
            if (word.mask & ~token.mask).nonzeroBitCount > word.editBudget { continue }
            if editDistance(word.chars, token.chars, limit: word.editBudget) <= word.editBudget {
                return true
            }
        }
        return false
    }

    /// Which characters a word contains, folded into 64 buckets.
    ///
    /// Collisions only ever make the filter *weaker* — two different characters sharing a bucket
    /// look present when one is absent — so a pair it admits still goes to the real walk and a
    /// pair it rejects genuinely needs more edits than the budget allows. That asymmetry is what
    /// makes a lossy filter safe here.
    public static func characterMask(_ chars: [Character]) -> UInt64 {
        var mask: UInt64 = 0
        for character in chars {
            guard let scalar = character.unicodeScalars.first else { continue }
            mask |= 1 << UInt64(scalar.value & 63)
        }
        return mask
    }

    /// Damerau-Levenshtein — insertion, deletion, substitution and adjacent transposition each
    /// cost 1. Answers the same number `search.py`'s own full matrix does for every pair whose
    /// distance is within `limit`; above it, only that the pair is beyond the limit, which is
    /// all any caller here asks.
    ///
    /// Two things keep this affordable across a whole vault on every keystroke, and both matter:
    /// abandoning a row whose cheapest cell already exceeds the budget rejects the overwhelming
    /// majority of pairs after a row or two, and the three DP rows come from a stack allocation
    /// rather than the heap — the pair count is in the tens of thousands per keystroke, which is
    /// exactly the scale at which small allocations stop being free.
    public static func editDistance(_ x: [Character], _ y: [Character], limit: Int) -> Int {
        // A length gap alone costs that many insertions, so it is already a lower bound.
        if abs(x.count - y.count) > limit { return limit + 1 }
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        let width = y.count + 1
        return withUnsafeTemporaryAllocation(of: Int.self, capacity: width * 3) { scratch in
            var previous2 = UnsafeMutableBufferPointer(rebasing: scratch[0..<width])
            var previous = UnsafeMutableBufferPointer(rebasing: scratch[width..<(2 * width)])
            var current = UnsafeMutableBufferPointer(rebasing: scratch[(2 * width)..<(3 * width)])
            for j in 0..<width {
                previous2[j] = 0
                previous[j] = j
            }

            for i in 1...x.count {
                current[0] = i
                var rowMin = i
                for j in 1...y.count {
                    let cost = x[i - 1] == y[j - 1] ? 0 : 1
                    var value = min(current[j - 1] + 1, previous[j] + 1, previous[j - 1] + cost)
                    if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                        value = min(value, previous2[j - 2] + 1)
                    }
                    current[j] = value
                    rowMin = min(rowMin, value)
                }
                if rowMin > limit { return limit + 1 }
                // Rotate rather than copy: `current` is fully overwritten at the top of the next
                // pass, so the oldest row is free to reuse.
                let recycled = previous2
                previous2 = previous
                previous = current
                current = recycled
            }
            return previous[y.count]
        }
    }

    /// String convenience, for callers with nothing to cache.
    public static func editDistance(_ a: String, _ b: String, limit: Int = Int.max) -> Int {
        let x = Array(a)
        let y = Array(b)
        let bound = limit == Int.max ? max(x.count, y.count) : limit
        return editDistance(x, y, limit: bound)
    }
}
