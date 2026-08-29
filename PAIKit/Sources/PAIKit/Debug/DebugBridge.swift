// Network.framework is Apple-only; the router and log ring beside this file are not, and
// they hold the logic worth testing.
#if DEBUG && canImport(Network)

    import Foundation
    import Network

    /// A tiny HTTP listener on loopback, present in debug builds only.
    ///
    /// **Why this reaches the host at all:** a simulator shares the Mac's network stack, so a
    /// listener bound to 127.0.0.1 inside the app is reachable as `127.0.0.1` *on the Mac*. No
    /// port forwarding, no `simctl` plumbing — `curl` from the build host just works. On a real
    /// device it would need a tunnel, which is one more reason the simulator is where the agent
    /// loop lives.
    ///
    /// Bound to loopback rather than any interface deliberately: nothing outside the machine
    /// should reach it, even in a debug build.
    public final class DebugBridge: @unchecked Sendable {

        public static let defaultPort: UInt16 = 8765

        private let port: NWEndpoint.Port
        private let router: DebugRouter
        private var listener: NWListener?
        private let queue = DispatchQueue(label: "pai.debug-bridge")

        public init(router: DebugRouter, port: UInt16 = DebugBridge.defaultPort) {
            self.router = router
            self.port = NWEndpoint.Port(rawValue: port) ?? .any
        }

        /// Never throws to the caller: a debug facility that prevents the app from launching
        /// would be worse than one that is simply absent, and the port may legitimately be taken
        /// by an earlier run that has not yet released it.
        public func start() {
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                // The port goes here and *only* here. Passing it to `NWListener(using:on:)` as
                // well is rejected — "Local endpoint has port set, cannot override" — and the
                // listener then never binds, while `start` still reports no error. Silent.
                parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)

                // Read out of `self` before the closure below, which must not capture it.
                let boundPort = port.rawValue
                let listener = try NWListener(using: parameters)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                // `start` returns without error even when the listener goes on to fail, so
                // without this a dead bridge is indistinguishable from a working one until
                // something tries to connect and times out.
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        DebugLogBuffer.shared.append(
                            .info, "debug-bridge", "listening on 127.0.0.1:\(boundPort)")
                    case .failed(let error), .waiting(let error):
                        DebugLogBuffer.shared.append(.error, "debug-bridge", "listener: \(error)")
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                DebugLogBuffer.shared.append(.error, "debug-bridge", "could not listen: \(error)")
            }
        }

        public func stop() {
            listener?.cancel()
            listener = nil
        }

        private func accept(_ connection: NWConnection) {
            connection.start(queue: queue)
            receive(connection, accumulated: Data())
        }

        /// Accumulates until the head — and any declared body — has arrived. A request split
        /// across packets is normal, and treating a partial read as a malformed request is the
        /// classic way a hand-rolled listener becomes flaky under load.
        private func receive(_ connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                [weak self] chunk, _, isComplete, error in
                guard let self else { return }

                var buffer = accumulated
                if let chunk { buffer.append(chunk) }

                if let request = DebugRouter.parse(buffer) {
                    let response = self.router.handle(request)
                    connection.send(
                        content: DebugRouter.serialize(response),
                        completion: .contentProcessed { _ in connection.cancel() }
                    )
                    return
                }

                if error != nil || isComplete {
                    connection.cancel()
                    return
                }
                self.receive(connection, accumulated: buffer)
            }
        }
    }

#endif
