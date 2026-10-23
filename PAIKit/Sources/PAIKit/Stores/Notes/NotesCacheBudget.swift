import Foundation

/// Which cached attachments to drop to bring the notes cache under its budget.
///
/// Only attachments are ever chosen: the index and bodies are what make the app usable offline
/// at all, and together they are bounded by the vault, far below any budget the setting offers.
/// They still count toward the total, so a large vault leaves less room for files.
public enum NotesCacheBudget {
    /// The budget a fresh install starts with — enough for hundreds of PDFs and thousands of
    /// images without the user noticing the space on a phone.
    public static let defaultBytes = 5 * gigabyte
    /// What the setting offers.
    public static let choices = [1 * gigabyte, 5 * gigabyte, 20 * gigabyte, 50 * gigabyte]

    static let gigabyte = 1_000_000_000

    /// The file ids to remove, least recently used first, until attachments plus `metadataBytes`
    /// fit in `budgetBytes`. Empty when everything already fits.
    public static func evictions(
        attachments: [CachedAttachment], metadataBytes: Int, budgetBytes: Int
    ) -> [String] {
        var total = metadataBytes + attachments.reduce(0) { $0 + $1.byteCount }
        guard total > budgetBytes else { return [] }
        let oldestFirst = attachments.sorted { lhs, rhs in
            lhs.lastUsedMs != rhs.lastUsedMs ? lhs.lastUsedMs < rhs.lastUsedMs : lhs.fileId < rhs.fileId
        }
        var evicted: [String] = []
        for entry in oldestFirst {
            guard total > budgetBytes else { break }
            evicted.append(entry.fileId)
            total -= entry.byteCount
        }
        return evicted
    }

    /// Whether a file this large is worth writing at all. One larger than the whole budget would
    /// only evict everything else and then itself; it is served from memory and never stored.
    public static func admits(byteCount: Int, budgetBytes: Int) -> Bool {
        byteCount <= budgetBytes
    }
}
