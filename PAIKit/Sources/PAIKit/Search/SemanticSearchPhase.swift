import Foundation

/// Where a semantic query stands while its text-match twin is already on screen.
///
/// A semantic search is slow on a bad day, so the list shows the plain text matches at once and
/// swaps in the tiered result when it lands. The phase says which of those the reader is looking
/// at.
public enum SemanticSearchPhase: Equatable, Sendable {
    /// No semantic query is running or wanted.
    case idle
    /// The text matches are showing, muted, until the tiered result lands.
    case searching
    /// The tiered result has replaced the text matches.
    case ready
    /// The server could not embed the query in time (any HTTP 503): the text matches stay.
    case unavailable
    /// Any other failure; the text matches stay and the message is shown.
    case failed(String)

    public static let searchingLabel = "Searching by meaning…"
    public static let unavailableLabel = "Semantic search is unavailable right now"

    /// How a failed semantic request ends.
    public static func outcome(of error: Error) -> SemanticSearchPhase {
        guard let error = error as? PaiError else { return .failed("\(error)") }
        return error.isSemanticUnavailable ? .unavailable : .failed(error.userMessage)
    }
}

/// Timings every search field shares.
public enum SearchTiming {
    /// Typed text waits this long for more typing before a request goes out.
    public static let debounceNanos: UInt64 = 300_000_000
}
