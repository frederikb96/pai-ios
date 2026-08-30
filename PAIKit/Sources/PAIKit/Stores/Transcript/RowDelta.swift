import Foundation

/// How a transcript's loaded row-id list changed since the last measurement pass.
///
/// A transcript's loaded window is always a contiguous, ascending suffix (``TranscriptWindow``'s
/// own doc comment) — ids are never reordered and never removed except by a whole-session LRU
/// eviction the collection view never sees, since that only ever targets a *different* session.
/// So the only shapes a change can take are these four, and telling them apart this way is what
/// lets each get exactly the scroll treatment it needs, instead of one generic diff that cannot
/// distinguish "grew at the top" from "grew at the bottom".
public enum RowDelta: Equatable, Sendable {
    case unchanged
    case appended(count: Int)
    case prepended(count: Int)
    /// Anything else — should not happen given the invariant above, but a full reload is the
    /// honest fallback rather than a crash if it ever does.
    case replaced

    public static func compute(old: [Int], new: [Int]) -> RowDelta {
        if old == new { return .unchanged }
        // Appended: the old ids are unchanged and still form the *front* of the new list, with
        // fresh ones added after — `old` is `new`'s prefix.
        if new.count > old.count, Array(new.prefix(old.count)) == old {
            return .appended(count: new.count - old.count)
        }
        // Prepended: older history was loaded in front of what was already there — `old` is
        // `new`'s suffix.
        if new.count > old.count, Array(new.suffix(old.count)) == old {
            return .prepended(count: new.count - old.count)
        }
        return .replaced
    }
}
