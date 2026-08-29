import Foundation

/// Swift port of `pai-cloud/web/src/utils/sessionFilter.ts`.
public enum SessionFilterMatch {
    /// Whether `query` reads as an id fragment — hex digits and dashes only — rather than
    /// ordinary words. The 8-character floor matches how this app shows an id elsewhere (the
    /// "Copy conversation id" hint is the first 8 characters) and rules out short all-hex English
    /// words ("cafe", "dead", "face", "beef") that would otherwise misroute a real title search.
    ///
    /// Decides which of two genuinely different searches the filter box performs: an id is only
    /// ever matched against sessions already loaded on the client (there is no id-search
    /// endpoint), while anything else is a text search that reaches the server's full corpus.
    ///
    /// Builds the regex on every call rather than caching it in a `static let`: `Regex` is not
    /// `Sendable` (its internal program representation is a reference type under the hood), so a
    /// shared global fails strict concurrency checking. `wholeMatch` anchors to the whole string
    /// on its own, matching the JS regex's `^...$` with no `m` flag.
    public static func looksLikeIdFragment(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = /[0-9a-f-]{8,}/.ignoresCase()
        return (try? pattern.wholeMatch(in: trimmed)) != nil
    }

    /// Plain substring match against a session's own id and Claude's conversation uuid — a whole
    /// one pasted from a log or a URL should find exactly its session. Never fuzzy: a uuid is a
    /// long run of hex digits, and a subsequence pass over one matches almost any short query,
    /// which would leave the list looking unfiltered.
    public static func sessionIdMatches(_ query: String, session: Session) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if needle.isEmpty { return true }
        return [session.id, session.claudeSessionId]
            .compactMap { $0 }
            .contains { $0.lowercased().contains(needle) }
    }

    /// Swift port of `pai-cloud/web/src/utils/directoryFilter.ts`'s `fuzzyMatchesSubsequence` —
    /// used by `DirectoryBrowserStore`, not the session list, but small enough to live beside the
    /// other text-matching rule this store domain needs rather than in a file of its own.
    ///
    /// Whether every character of `query` appears in `text`, in order, with anything allowed
    /// between them. Case-insensitive; an empty query matches everything. Deliberately not
    /// ranked/scored: the working-directory picker keeps its list alphabetical and only ever
    /// narrows it, never reorders survivors by how well they matched.
    public static func fuzzyMatchesSubsequence(_ query: String, _ text: String) -> Bool {
        let needle = Array(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        if needle.isEmpty { return true }
        let haystack = text.lowercased()
        var index = 0
        for character in haystack where index < needle.count {
            if character == needle[index] { index += 1 }
        }
        return index == needle.count
    }
}
