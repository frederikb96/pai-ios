import Foundation

public enum NoteNaming {

    /// What a note is called when nobody has named it.
    public static let untitled = "Untitled"

    /// `base`, or `base 2`, `base 3`… — the first spelling no existing note is using.
    ///
    /// A note's name is a filename in a synced folder, so the backend refuses a duplicate. That is
    /// right for a rename, where the name is the point, and wrong for creating one: every system
    /// that makes new files makes a second `Untitled` without asking, and an error instead is a
    /// dead end with no way forward except inventing a name before there is anything to name.
    ///
    /// Compared case- and diacritic-insensitively, because the folder may sit on a volume that
    /// treats `Notes` and `notes` as the same file.
    public static func freeName(base: String, taken: [String]) -> String {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = trimmed.isEmpty ? untitled : trimmed
        let used = Set(taken.map(normalizeForNoteSearch))
        guard used.contains(normalizeForNoteSearch(root)) else { return root }
        var suffix = 2
        while used.contains(normalizeForNoteSearch("\(root) \(suffix)")) { suffix += 1 }
        return "\(root) \(suffix)"
    }
}
