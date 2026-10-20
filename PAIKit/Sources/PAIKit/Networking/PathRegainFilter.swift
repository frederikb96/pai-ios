/// Turns the stream of path updates into the one thing retry logic wants to know: the network
/// came back. `NWPathMonitor` reports every change of interface, gateway or DNS, not only changes
/// of reachability, so a link that is up and merely reconfiguring (a VPN switching, Wi-Fi roaming)
/// produces a run of "satisfied" updates. Treating each as a regain would cancel every retry
/// backoff each time.
public struct PathRegainFilter: Sendable {
    private var satisfied: Bool?

    public init() {}

    /// Whether this update is a regain: satisfied now, and not satisfied before. The first update
    /// only establishes the starting state, so a monitor being started is never a regain.
    public mutating func regained(satisfied now: Bool) -> Bool {
        defer { satisfied = now }
        return now && satisfied == false
    }
}
