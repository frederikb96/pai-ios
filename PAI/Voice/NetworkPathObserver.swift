import Foundation
import Network
import PAIKit

/// Feeds `ConnectionHealthEvent.pathSatisfied` from `NWPathMonitor` — the one input
/// `ConnectionHealth` needs that this app has to supply itself, since path satisfaction is a
/// platform observation a realtime socket cannot report about itself. A closed socket only says
/// the socket closed; this is what says whether retrying it is even worth attempting — no
/// reconnect attempt should be made while the path itself is unsatisfied.
final class NetworkPathObserver: @unchecked Sendable {
    var onEvent: (@Sendable (ConnectionHealthEvent) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.frederikberg.pai.network-path-observer")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.onEvent?(.pathSatisfied(path.status == .satisfied))
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
