import Foundation

/// What a note's content hash moving underneath an open editor actually means.
///
/// Swift port of `pai-cloud/web/src/apps/notes/editor/noteConflict.ts`, and the same reasoning:
/// a note's `content_hash` is one sha over frontmatter *and* body, so anything touching the
/// frontmatter alone moves it — the sync engine writing a version back from disk, a summary
/// saved from the info panel, a uuid backfilled into a note reaching a container for the first
/// time. None of those has anything to say about the paragraph being typed, and `PATCH
/// /api/notes/{id}` merges the stored frontmatter regardless of what a client sends. So a
/// divergence the body cannot see is one where keeping the local text loses nothing that existed.
///
/// That is why the conflict banner appeared so often: two writers with no overlap at all still
/// collide on one shared hash.
public enum NoteBodyDivergence: Equatable, Sendable {
    /// The server's body is exactly what this client was editing from — whatever moved the hash
    /// was outside the body, and there is nothing to ask about.
    case none
    /// The server already holds what this client was about to write; another route delivered the
    /// same text. Nothing to keep and nothing to lose.
    case alreadyOurs
    /// Two different bodies, neither of them ours. The one case the banner exists for.
    case real

    /// `server` is the body the server holds now, `base` the one this client last knew it to
    /// hold, `local` what the editor would write if it saved right now.
    ///
    /// A `nil` server body is an empty one — the wire omits an empty string — and empty is an
    /// ordinary note body rather than a missing value, so it is compared like any other.
    public static func of(server: String?, base: String?, local: String) -> NoteBodyDivergence {
        let serverBody = server ?? ""
        if serverBody == (base ?? "") { return .none }
        if serverBody == local { return .alreadyOurs }
        return .real
    }
}
