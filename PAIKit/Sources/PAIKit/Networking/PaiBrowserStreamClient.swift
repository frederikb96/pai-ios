import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// SSE client for one agent browser session's live view
/// (`GET /api/browser/sessions/{name}/stream`). Swift port of
/// `pai-cloud/web/src/apps/browser/browserStream.ts`.
///
/// Shaped like ``PaiTerminalStreamClient`` — no cursor, no replay, the backend sends the newest
/// state and frame to every viewer that joins — but events are named (`frame`, `state`, `end`,
/// `ping`), and `end` is final: the client stops itself and is never retried. A refused stream
/// (403 not the owner, 404 no such session) ends the same way, since retrying cannot change it.
@MainActor
public final class PaiBrowserStreamClient {

    public struct Callbacks: Sendable {
        public var onEvent: @MainActor @Sendable (BrowserStreamEvent) -> Void
        public var onConnected: @MainActor @Sendable () -> Void
        public var onDisconnected: @MainActor @Sendable () -> Void

        public init(
            onEvent: @escaping @MainActor @Sendable (BrowserStreamEvent) -> Void,
            onConnected: @escaping @MainActor @Sendable () -> Void,
            onDisconnected: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onEvent = onEvent
            self.onConnected = onConnected
            self.onDisconnected = onDisconnected
        }
    }

    private static let initialBackoffNanos: UInt64 = 1_000_000_000
    private static let maxBackoffNanos: UInt64 = 15_000_000_000
    /// The backend pings every 15 s; three missed pings is stale. See `PaiTerminalStreamClient`.
    private static let staleTimeout: TimeInterval = 45
    private static let watchdogIntervalNanos: UInt64 = 10_000_000_000

    private let sessionName: String
    private let requestFactory: PaiRequestFactory
    private let urlSessionConfiguration: URLSessionConfiguration
    private let callbacks: Callbacks

    private var backoffNanos = PaiBrowserStreamClient.initialBackoffNanos
    private var lastEventTime = Date()
    private var stopped = false
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeByteStream: PaiHttpByteStream?

    public init(
        sessionName: String,
        requestFactory: PaiRequestFactory,
        callbacks: Callbacks,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.sessionName = sessionName
        self.requestFactory = requestFactory
        self.callbacks = callbacks
        self.urlSessionConfiguration = urlSessionConfiguration
    }

    public func connect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        streamTask = Task { await self.runConnection() }
    }

    public func disconnect() {
        guard !stopped else { return }
        stopped = true
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        watchdogTask?.cancel()
        callbacks.onDisconnected()
    }

    private func runConnection() async {
        guard
            let request = try? requestFactory.makeRequest(
                path: PaiApiClient.browserSessionPath(sessionName) + "/stream")
        else {
            handleDisconnect()
            return
        }

        let byteStream = PaiHttpByteStream()
        activeByteStream = byteStream

        var splitter = LineSplitter()
        var accumulator = SseEventAccumulator()

        do {
            for try await event in byteStream.start(request: request, configuration: urlSessionConfiguration) {
                if Task.isCancelled { break }
                switch event {
                case .connected:
                    backoffNanos = Self.initialBackoffNanos
                    lastEventTime = Date()
                    callbacks.onConnected()
                    startWatchdog()
                case .chunk(let data):
                    for line in splitter.ingest(data) {
                        // A record boundary is activity even when the record is a bare ping.
                        if line.isEmpty { lastEventTime = Date() }
                        guard let record = accumulator.ingest(line: line) else { continue }
                        guard let parsed = BrowserStreamEvent.parse(name: record.name, data: record.data) else {
                            continue
                        }
                        deliver(parsed)
                        if stopped { return }
                    }
                }
            }
            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect()
            }
        } catch {
            guard Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) else {
                return
            }
            if let reason = Self.finalReason(for: error) {
                deliver(.end(reason: reason))
            } else {
                handleDisconnect()
            }
        }
    }

    /// An `end` event is final, so the client stops itself before anyone is told.
    private func deliver(_ event: BrowserStreamEvent) {
        if case .end = event {
            stopped = true
            reconnectTask?.cancel()
            watchdogTask?.cancel()
            activeByteStream?.cancel()
        }
        callbacks.onEvent(event)
    }

    /// What a refused stream says, when retrying cannot change the answer.
    nonisolated static func finalReason(for error: Error) -> String? {
        guard let streamError = error as? PaiHttpByteStream.StreamError,
            case .unexpectedStatus(let status) = streamError
        else { return nil }
        switch status {
        case 403: return "Only the owner can open browser sessions"
        case 404: return "No such browser session"
        default: return nil
        }
    }

    nonisolated static func shouldReconnectAfterStreamEnded(cancelled: Bool, stopped: Bool) -> Bool {
        !cancelled && !stopped
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.watchdogIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastEventTime) > Self.staleTimeout {
                    self.handleDisconnect()
                }
            }
        }
    }

    private func handleDisconnect() {
        callbacks.onDisconnected()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        watchdogTask?.cancel()
        guard !stopped else { return }

        let delay = backoffNanos
        backoffNanos = min(backoffNanos * 2, Self.maxBackoffNanos)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }
}
