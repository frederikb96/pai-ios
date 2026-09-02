import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The account-wide notification stream (`GET /api/notifications/stream`) — a new row arriving
/// anywhere, or the unread count moving because something was marked read anywhere (row 5.27
/// note 1, row 24.5). Reuses the same framing pieces `PaiSseClient` does
/// (`PaiHttpByteStream`/`LineSplitter`/`SseEventAccumulator`), and its own tested
/// `shouldReconnectAfterStreamEnded` rule, but is a separate, simpler client rather than a second
/// mode of that one: this stream carries no cursor and no terminal status — the backend replays
/// no history (`_notifications_sse_generator`'s own doc comment), so there is nothing to resume
/// from and nothing that ever ends the connection from the server side.
///
/// Deliberately **not** held open for the app's whole lifetime the way the web keeps one
/// `EventSource` open per tab. A phone suspends network activity within seconds of
/// backgrounding unless a background mode is declared, and none of PAI's existing background
/// modes exist for this — holding a stream "open" while suspended would just be a connection
/// nobody is reading, reopened from scratch on the next foreground regardless. So the intended
/// caller connects this only while the app is actually in front of the reader (`scenePhase ==
/// .active`) and disconnects on backgrounding, the same foreground-only shape
/// `AppEnvironment.pollNotificationSummary()` already uses for the same reason, one layer up.
/// That poll keeps running unchanged alongside this stream as the self-heal for whatever a gap
/// in the stream — a missed event while reconnecting, or the reader having been backgrounded —
/// never replays; see that function's own doc comment.
@MainActor
public final class PaiNotificationStreamClient {

    /// Every closure is `@MainActor` as well as `@Sendable`, for the same reason
    /// `PaiSseClient.Callbacks` is: this client itself is `@MainActor`, and every realistic
    /// caller is a `@MainActor` store or view model.
    public struct Callbacks: Sendable {
        public var onNotification: @MainActor @Sendable (SseNotificationEvent) -> Void
        public var onRead: @MainActor @Sendable (SseNotificationReadEvent) -> Void
        /// Fired for every successfully-parsed record, including a bare `ping` with no
        /// `onNotification`/`onRead` counterpart — see `PaiSseClient.Callbacks.onActivity`.
        public var onActivity: @MainActor @Sendable () -> Void
        public var onConnected: @MainActor @Sendable () -> Void
        public var onDisconnected: @MainActor @Sendable () -> Void

        public init(
            onNotification: @escaping @MainActor @Sendable (SseNotificationEvent) -> Void,
            onRead: @escaping @MainActor @Sendable (SseNotificationReadEvent) -> Void,
            onActivity: @escaping @MainActor @Sendable () -> Void,
            onConnected: @escaping @MainActor @Sendable () -> Void,
            onDisconnected: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onNotification = onNotification
            self.onRead = onRead
            self.onActivity = onActivity
            self.onConnected = onConnected
            self.onDisconnected = onDisconnected
        }
    }

    private static let initialBackoffNanos: UInt64 = 2_000_000_000
    private static let maxBackoffNanos: UInt64 = 30_000_000_000
    private static let staleTimeout: TimeInterval = 45
    private static let watchdogIntervalNanos: UInt64 = 10_000_000_000

    private let requestFactory: PaiRequestFactory
    private let urlSessionConfiguration: URLSessionConfiguration
    private let callbacks: Callbacks

    private var backoffNanos = PaiNotificationStreamClient.initialBackoffNanos
    private var lastEventTime = Date()
    private var stopped = false
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeByteStream: PaiHttpByteStream?

    public init(
        requestFactory: PaiRequestFactory,
        callbacks: Callbacks,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.requestFactory = requestFactory
        self.callbacks = callbacks
        self.urlSessionConfiguration = urlSessionConfiguration
    }

    /// Safe to call while already connected — tears down whatever is in flight first, the same
    /// as `PaiSseClient.connect()`. `disconnect()` latches `stopped` permanently; this only ever
    /// reopens a connection that has not been explicitly stopped.
    public func connect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        streamTask = Task { await self.runConnection() }
    }

    /// A deliberate, caller-initiated stop — going to the background. Safe to call more than
    /// once; a second `connect()` on the same instance is refused, matching `PaiSseClient`'s own
    /// one-shot-per-instance lifetime. The caller builds a fresh client on the next foreground.
    public func disconnect() {
        stopped = true
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        watchdogTask?.cancel()
        callbacks.onDisconnected()
    }

    private func runConnection() async {
        guard let request = try? requestFactory.makeRequest(path: "/api/notifications/stream") else {
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
                        if let sseEvent = accumulator.ingest(line: line) {
                            handleEvent(name: sseEvent.name, data: sseEvent.data)
                        }
                    }
                }
            }
            // No terminal status on this stream (see this type's own doc comment), so the only
            // two reasons to stop reconnecting are the ones `PaiSseClient` already names: a
            // deliberate cancel, or an explicit `disconnect()`.
            if PaiSseClient.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, terminal: false, stopped: stopped)
            {
                handleDisconnect()
            }
        } catch {
            if PaiSseClient.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, terminal: false, stopped: stopped)
            {
                handleDisconnect()
            }
        }
    }

    private func handleEvent(name: String, data: String) {
        lastEventTime = Date()
        callbacks.onActivity()
        guard let jsonData = data.data(using: .utf8) else { return }

        switch name {
        case "notification":
            guard let event = try? JSONDecoder().decode(SseNotificationEvent.self, from: jsonData) else { return }
            callbacks.onNotification(event)

        case "read":
            guard let event = try? JSONDecoder().decode(SseNotificationReadEvent.self, from: jsonData) else { return }
            callbacks.onRead(event)

        case "ping":
            break  // No-op handler that exists only to advance `lastEventTime`, already done above.

        default:
            break
        }
    }

    private func startWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: Self.watchdogIntervalNanos)
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.lastEventTime) > Self.staleTimeout {
                    self.scheduleReconnect()
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
