import Foundation

/// How a semantic result list is presented. The backend assigns each hit a tier (`1` likely,
/// `2` less likely) and orders the list by it; a client draws tier-1 rows with no header and one
/// muted divider before the first tier-2 row, and never sees a score threshold.
public enum SearchTier {
    public static let lessLikelyTitle = "Less likely"

    public static func isLessLikely(_ tier: Int?) -> Bool {
        guard let tier else { return false }
        return tier >= 2
    }

    /// The index of the row the divider sits above, `nil` when the list has no tier-2 row.
    public static func lessLikelyDividerIndex(in tiers: [Int?]) -> Int? {
        tiers.firstIndex(where: isLessLikely)
    }
}
