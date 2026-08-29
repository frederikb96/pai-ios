import Foundation

/// Per-session bookkeeping for the loaded window: a contiguous suffix of the transcript,
/// `[oldestLoadedId .. latest]`. Never a disjoint range — every merge path (bootstrap, older
/// page, SSE) preserves that, which is what lets restoring a scroll anchor and paging older both
/// stay simple lookups instead of segment arithmetic.
///
/// Swift port of `pai-cloud/web/src/stores/messages.ts`'s `SessionWindow`.
public struct TranscriptWindow: Equatable, Sendable {
    public var oldestLoadedId: Int?
    public var hasOlder: Bool
    public var bootstrapped: Bool
    public var bootstrapping: Bool
    public var bootstrapError: String?
    public var loadingOlder: Bool
    public var olderError: String?

    public init(
        oldestLoadedId: Int? = nil,
        hasOlder: Bool = false,
        bootstrapped: Bool = false,
        bootstrapping: Bool = false,
        bootstrapError: String? = nil,
        loadingOlder: Bool = false,
        olderError: String? = nil
    ) {
        self.oldestLoadedId = oldestLoadedId
        self.hasOlder = hasOlder
        self.bootstrapped = bootstrapped
        self.bootstrapping = bootstrapping
        self.bootstrapError = bootstrapError
        self.loadingOlder = loadingOlder
        self.olderError = olderError
    }

    public static let empty = TranscriptWindow()
}
