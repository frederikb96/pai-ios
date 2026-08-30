import Foundation

/// How a transcript's loaded row-id list changed since the last measurement pass.
///
/// A transcript's loaded window is a contiguous, ascending run of server rows (``TranscriptWindow``'s
/// own doc comment) — ids are never reordered and never removed except by a whole-session LRU
/// eviction the collection view never sees, since that only ever targets a *different* session.
/// The one thing that does change at the tail is the pending-send bubbles the view appends after
/// them, which stand in for sends the server has not confirmed yet.
///
/// Telling these shapes apart is what lets each get exactly the scroll treatment it needs,
/// instead of one generic diff that cannot distinguish "grew at the top" from "grew at the
/// bottom" — and, crucially, cannot distinguish either from "the tail changed and nothing above
/// it did".
public enum RowDelta: Equatable, Sendable {
    case unchanged
    case appended(count: Int)
    case prepended(count: Int)
    /// The two lists share a leading run and differ only after it: `removed` rows dropped from
    /// the tail, `inserted` put in their place.
    ///
    /// This is what sending a message looks like — the bubble standing in for the unconfirmed
    /// send is dropped as the server's own row for it arrives, and nothing above the two moves.
    /// Folded into ``replaced`` it forced a full reload on the single most common interaction
    /// there is, which discards the reader's scroll anchor along with it.
    case tailReplaced(commonPrefix: Int, removed: Int, inserted: Int)
    /// Anything else — no shared leading run at all, so there is no anchor to preserve and a full
    /// reload is the honest answer.
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
        // Checked after the two above, which are the same shape with nothing removed, and which
        // the collection view can apply as a pure insert.
        let commonPrefix = zip(old, new).prefix { $0.0 == $0.1 }.count
        if commonPrefix > 0 {
            return .tailReplaced(
                commonPrefix: commonPrefix, removed: old.count - commonPrefix,
                inserted: new.count - commonPrefix)
        }
        return .replaced
    }
}
