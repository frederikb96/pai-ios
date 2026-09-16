import Foundation

/// Whether the take's connection to ElevenLabs is trustworthy enough to spend a backfill request
/// or a reserve-token mint on — fed events, no I/O of its own, so a scripted schedule against a
/// fake clock proves every transition. Runs app-wide, one instance per take's lifetime, not one
/// per socket: a reconnect opens a new socket but does not reset this machine's own view of
/// whether the *path* has been trustworthy lately.
public struct ConnectionHealth: Sendable, Equatable {
    /// How long a socket must stay open and delivering before a flapping connection can be
    /// called `stable` — long enough that a 3–5s drop cycle never reaches it.
    public static let stableAfterSeconds: TimeInterval = 10
    /// How long a close or a mint failure keeps the state at `unstable` even after a fresh socket
    /// opens — the window a "still unstable" cue (`FeedbackPolicy`) and a backfill gate both read.
    public static let recentFailureWindowSeconds: TimeInterval = 30

    public private(set) var state: HealthState = .offline

    private var pathSatisfied = false
    private var socketOpenedAt: Date?
    private var hasDelivered = false
    private var lastFailureAt: Date?

    public init() {}

    /// Every case but `.tick` reacts as of `now`; `.tick` exists purely to let a caller force a
    /// recompute (the 10s/30s windows elapsing with no new event) — its own payload is redundant
    /// with `now` and is not read.
    @discardableResult
    public mutating func handle(_ event: ConnectionHealthEvent, now: Date) -> HealthState {
        switch event {
        case let .pathSatisfied(satisfied):
            pathSatisfied = satisfied
            if !satisfied {
                socketOpenedAt = nil
                hasDelivered = false
            }
        case .socketOpened:
            socketOpenedAt = now
            hasDelivered = false
        case .socketDelivered:
            hasDelivered = true
        case .socketClosed:
            socketOpenedAt = nil
            hasDelivered = false
            lastFailureAt = now
        case .mintFailed:
            lastFailureAt = now
        case .mintSucceeded, .tick:
            break
        }
        recompute(now: now)
        return state
    }

    private mutating func recompute(now: Date) {
        guard pathSatisfied else {
            state = .offline
            return
        }
        guard let socketOpenedAt else {
            state = .connecting
            return
        }
        let openForSeconds = now.timeIntervalSince(socketOpenedAt)
        let recentFailure = lastFailureAt.map { now.timeIntervalSince($0) < Self.recentFailureWindowSeconds } ?? false
        let stable = hasDelivered && openForSeconds >= Self.stableAfterSeconds && !recentFailure
        state = stable ? .stable : .unstable
    }
}
