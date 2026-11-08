import Foundation

extension DecisionMarkers {

    /// `text` without its decision marker lines, for a place that draws no card: the notification
    /// list, where the open decisions already lead the body. Port of the web's
    /// `withoutDecisionMarkers`.
    public static func withoutMarkers(_ text: String) -> String {
        split(text).compactMap { segment -> String? in
            if case .markdown(let markdown) = segment { markdown } else { nil }
        }.joined(separator: "\n")
    }
}
