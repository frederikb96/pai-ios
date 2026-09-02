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
    /// The newer edge, symmetric to the older one above — `nil`/`false` for a tail bootstrap,
    /// which is at the tail by definition. What lands a window whose newest loaded message is
    /// not the session's newest is a jump to a distant search hit or deep link
    /// (`mergeWindow`/`replaceWindow`); this is the state that lets one, once it exists, page
    /// forward from wherever it landed instead of only ever growing backward.
    public var newestLoadedId: Int?
    public var hasNewer: Bool
    public var loadingNewer: Bool
    public var newerError: String?

    public init(
        oldestLoadedId: Int? = nil,
        hasOlder: Bool = false,
        bootstrapped: Bool = false,
        bootstrapping: Bool = false,
        bootstrapError: String? = nil,
        loadingOlder: Bool = false,
        olderError: String? = nil,
        newestLoadedId: Int? = nil,
        hasNewer: Bool = false,
        loadingNewer: Bool = false,
        newerError: String? = nil
    ) {
        self.oldestLoadedId = oldestLoadedId
        self.hasOlder = hasOlder
        self.bootstrapped = bootstrapped
        self.bootstrapping = bootstrapping
        self.bootstrapError = bootstrapError
        self.loadingOlder = loadingOlder
        self.olderError = olderError
        self.newestLoadedId = newestLoadedId
        self.hasNewer = hasNewer
        self.loadingNewer = loadingNewer
        self.newerError = newerError
    }

    public static let empty = TranscriptWindow()
}
