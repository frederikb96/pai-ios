import Foundation

/// A note just created, waiting for its freshly pushed editor to focus and select its title.
///
/// A one-shot side channel rather than a flag on ``Route``, for the same reason
/// ``DeepLinkInbox`` is one: `Route.note(id:)` can be restored from a persisted path on
/// relaunch, months after a note was actually created, and re-focusing its title then would be
/// wrong — this concept must never be something a route can carry across a restore. It holds the
/// signal only across the single push that immediately follows creation.
@MainActor
public final class NoteCreationFocus {
    public static let shared = NoteCreationFocus()

    private var pendingNoteID: String?

    public init() {}

    /// Called right before pushing the newly created note's editor.
    public func markCreated(id: String) {
        pendingNoteID = id
    }

    /// Whether `id` is the note that was just created — true at most once, and only for the note
    /// that was actually marked. Consumes the signal either way, so a later `onAppear` for the
    /// same screen (a rotation, a resume) does not refocus the title a second time.
    public func consume(id: String) -> Bool {
        guard pendingNoteID == id else { return false }
        pendingNoteID = nil
        return true
    }
}
