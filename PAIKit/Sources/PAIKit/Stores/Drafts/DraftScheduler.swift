import Foundation

/// The delayed-flush half of `DraftStore`'s debounce, pulled out as a dependency rather than a
/// bare `Task.sleep` so a test can make the debounce resolve instantly and still exercise the
/// real cancel-and-restart behaviour through a real (if instant) suspension point — a fixed
/// sleep here would make the debounce window part of every test's running time, and skipping the
/// suspension entirely would stop `Task` cancellation from ever having a point to land on.
public protocol DraftScheduler: Sendable {
    func sleep(seconds: TimeInterval) async throws
}

public struct RealDraftScheduler: DraftScheduler {
    public init() {}

    public func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64((seconds * 1_000_000_000).rounded()))
    }
}
