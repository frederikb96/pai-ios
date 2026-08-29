import Foundation

/// The retry schedule for the tail bootstrap fetch that runs before a transcript's SSE stream
/// connects for the first time — 2s, 4s, 8s, … capped at 30s, matching `PaiSseClient`'s own
/// reconnect backoff (independent state; a bootstrap retry never touches that client, which is
/// not created until the bootstrap succeeds).
///
/// A failed bootstrap must retry rather than fall back to a cursorless SSE connect, which would
/// resurrect a full-history replay exactly when the backend is already struggling — this type
/// only owns the delay schedule for that retry, not the retry loop itself.
public struct TranscriptBootstrapBackoff: Equatable, Sendable {
    public static let initial: Duration = .seconds(2)
    public static let maximum: Duration = .seconds(30)

    public private(set) var current: Duration

    public init() {
        current = Self.initial
    }

    /// The delay to wait before the next attempt, advancing the schedule for the one after that.
    public mutating func next() -> Duration {
        let delay = current
        current = min(current * 2, Self.maximum)
        return delay
    }
}
