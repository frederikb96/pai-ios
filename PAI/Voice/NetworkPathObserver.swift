import Foundation
import Network
import PAIKit

/// Feeds `ConnectionHealthEvent.pathSatisfied` from `NWPathMonitor` — the one input
/// `ConnectionHealth` needs that this app has to supply itself, since path satisfaction is a
/// platform observation a realtime socket cannot report about itself. A closed socket only says
/// the socket closed; this is what says whether retrying it is even worth attempting — no
/// reconnect attempt should be made while the path itself is unsatisfied.
final class NetworkPathObserver: @unchecked Sendable {
    /// Every path update, as `ConnectionHealth` wants it.
    var onEvent: (@Sendable (ConnectionHealthEvent) -> Void)?
    /// Only the update that follows an unsatisfied one — what "retry now" and "refetch" belong on.
    /// `onEvent` also fires for a link that stays up while its interface or DNS changes.
    var onRegained: (@Sendable () -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.frederikberg.pai.network-path-observer")
    /// Touched only from `queue`, where `pathUpdateHandler` runs.
    private var regainFilter = PathRegainFilter()

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            onEvent?(.pathSatisfied(satisfied))
            if regainFilter.regained(satisfied: satisfied) { onRegained?() }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
    }
}
