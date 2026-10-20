/// The kind of link a satisfied path runs over, reduced to what a retry decision needs.
public enum PathInterface: Sendable, Equatable {
    case wifi, cellular, wired, other
}

/// Turns the stream of path updates into the one thing retry logic wants to know: this is a
/// network the app has not been talking over. `NWPathMonitor` reports every change of interface,
/// gateway or DNS, not only changes of reachability, so a link that is up and merely
/// reconfiguring produces a run of identical "satisfied" updates. Treating each as news would
/// cancel every retry backoff each time. What does count is the network coming back, and the
/// primary interface changing under a path that stayed up (Wi-Fi to cellular on the move).
public struct PathRegainFilter: Sendable {
    private var satisfied: Bool?
    private var interface: PathInterface?

    public init() {}

    /// Whether this update is news: satisfied now and either not satisfied before or over a
    /// different primary interface. The first update only establishes the starting state, so a
    /// monitor being started is never news.
    public mutating func regained(satisfied now: Bool, interface nowInterface: PathInterface?) -> Bool {
        defer {
            satisfied = now
            interface = now ? nowInterface : nil
        }
        guard now, let before = satisfied else { return false }
        return !before || interface != nowInterface
    }
}
