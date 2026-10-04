import Foundation

public enum NoteNaming {

    /// What a note is called when nobody has named it.
    public static let untitled = "Untitled"

    /// What a freshly created note is called — today's date, so it can be typed straight into
    /// rather than replaced first. Freddy's own day, not the server's: computed in Europe/Berlin
    /// so a note started near midnight lands on the day it felt like being written, not on
    /// whatever day UTC happens to be. The web client names a note created the same day
    /// identically, so both must compute this the same way.
    public static func todayName(now: Date = Date()) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin") ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = components.year, let month = components.month, let day = components.day
        else { return untitled }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Whether `name` already belongs to some other note in `containerId` — a fast, local
    /// preview of what the server's own rename check will say. Mirrors the backend's own rule
    /// (`repository.find_note_in_container`, `notes_service.find_rename_collision`) exactly,
    /// not a separate rule invented client-side: case-INSENSITIVE only — matched the way the
    /// backend's generated `name_key` column does (`lower(name)`), never diacritic-folded the
    /// way search's own `normalizeForNoteSearch` is, since a note name becomes a filename in a
    /// synced folder and most filesystems fold case but keep `Müller` and `Muller` distinct.
    /// Excludes a note pending delete — its name is free to reuse immediately, not held hostage
    /// by the undo window. A container-less note has NO collision domain at all (v1 has no
    /// uniqueness on a note's name outside a container), so `containerId == nil` is always
    /// `false` here too, never a match against every container.
    ///
    /// Not the rule: the server holds the real vault and is free to disagree (another device
    /// wrote a colliding name a moment ago), so a caller must still send the rename and read
    /// its answer rather than trusting this to gate the request. This exists only to paint a
    /// field invalid before that round trip, not to replace it.
    public static func collides(
        name: String, containerId: String?, excluding noteID: String, among notes: [NoteSummary]
    )
        -> Bool
    {
        guard let containerId else { return false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let target = trimmed.lowercased()
        return notes.contains { note in
            note.id != noteID && !note.pendingDelete
                && note.containerId == containerId
                && note.name.lowercased() == target
        }
    }
}
