import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Swift port of `pai-cloud/web/src/api/terminalStream.ts`. Deliberately not `PaiSseClient`: no
/// cursor, no replay — a terminal is a raw live view, not a resumable log — and a different
/// backoff. See that type's doc comment for why this authenticates natively via
/// `PaiRequestFactory` instead of the web's cookie, and why bytes arrive through
/// `PaiHttpByteStream`/`LineSplitter` rather than `URLSession.bytes(for:)`.
@MainActor
public final class PaiTerminalStreamClient {

    public struct Callbacks: Sendable {
        /// `live` is false while the frame is anchored to a scrolled-back offset. An
        /// absent or malformed `live` flag defaults to **true** — a stuck "scrolled back"
        /// banner nothing can clear is worse than briefly claiming to be live
        /// (`terminalStream.ts:52-55`).
        ///
        /// Every closure is `@MainActor` as well as `@Sendable` — see `PaiSseClient.Callbacks`'s
        /// doc comment for why: this type is `@MainActor` too, and a plain `@Sendable` closure
        /// would force isolation boilerplate at every wiring site for no benefit.
        public var onFrame: @MainActor @Sendable (_ chunk: String, _ live: Bool) -> Void
        public var onConnected: @MainActor @Sendable () -> Void
        public var onDisconnected: @MainActor @Sendable () -> Void

        public init(
            onFrame: @escaping @MainActor @Sendable (String, Bool) -> Void,
            onConnected: @escaping @MainActor @Sendable () -> Void,
            onDisconnected: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onFrame = onFrame
            self.onConnected = onConnected
            self.onDisconnected = onDisconnected
        }
    }

    private static let initialBackoffNanos: UInt64 = 1_000_000_000
    private static let maxBackoffNanos: UInt64 = 15_000_000_000
    /// Matches `PaiSseClient`'s own watchdog exactly — both streams share the same
    /// `SSE_PING_INTERVAL` (15s, `pai_cloud/api.py`), so the same "three missed pings is stale"
    /// shape applies unchanged. Without this, the only reconnect trigger was the read loop
    /// itself ending, which a half-open connection (a phone crossing from WiFi to cellular, say)
    /// never does on its own — the socket looks alive to the OS while nothing arrives.
    private static let staleTimeout: TimeInterval = 45
    private static let watchdogIntervalNanos: UInt64 = 10_000_000_000

    private let sessionId: String
    private let requestFactory: PaiRequestFactory
    private let urlSessionConfiguration: URLSessionConfiguration
    private let callbacks: Callbacks

    private var backoffNanos = PaiTerminalStreamClient.initialBackoffNanos
    private var lastEventTime = Date()
    private var stopped = false
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeByteStream: PaiHttpByteStream?

    public init(
        sessionId: String,
        requestFactory: PaiRequestFactory,
        callbacks: Callbacks,
        urlSessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.sessionId = sessionId
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
        stopped = true
        reconnectTask?.cancel()
        streamTask?.cancel()
        activeByteStream?.cancel()
        watchdogTask?.cancel()
        callbacks.onDisconnected()
    }

    private func runConnection() async {
        guard let request = try? requestFactory.makeRequest(path: "/api/session/\(sessionId)/terminal") else {
            handleDisconnect()
            return
        }

        let byteStream = PaiHttpByteStream()
        activeByteStream = byteStream

        var splitter = LineSplitter()
        var dataLines: [String] = []

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
                        if line.isEmpty {
                            // Every record boundary counts as activity, including a bare
                            // keepalive with no `data:` line — matching `PaiSseClient.handleEvent`,
                            // which advances its own `lastEventTime` before checking whether the
                            // record was one of its three semantic events.
                            lastEventTime = Date()
                            if !dataLines.isEmpty {
                                // Named `frame` events and a backend falling back to unnamed
                                // `message` events are handled identically —
                                // `terminalStream.ts` wires both to the same handler, so the
                                // event name itself is never branched on.
                                handleChunk(dataLines.joined(separator: "\n"))
                            }
                            dataLines = []
                            continue
                        }
                        if line.hasPrefix("data:") {
                            dataLines.append(Self.sseDataValue(from: line.dropFirst("data:".count)))
                        }
                        // `event:` is read but not branched on, per the comment above; other
                        // fields are unused.
                    }
                }
            }

            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect()
            }
        } catch {
            if Self.shouldReconnectAfterStreamEnded(cancelled: Task.isCancelled, stopped: stopped) {
                handleDisconnect()
            }
        }
    }

    /// See `PaiSseClient.sseDataValue(from:)` — same SSE framing rule, this stream's own copy
    /// since the two clients share no parsing code by design (see the type doc comment).
    nonisolated static func sseDataValue(from line: Substring) -> String {
        line.first == " " ? String(line.dropFirst()) : String(line)
    }

    /// See `PaiSseClient.shouldReconnectAfterStreamEnded(cancelled:terminal:stopped:)` — same
    /// double-reconnect bug, this client's own copy since it has its own `stopped`/no `terminal`
    /// state; the race is the same one `startWatchdog()` can trigger here too now, on top of
    /// `connect()` cancelling a still-running `streamTask`.
    nonisolated static func shouldReconnectAfterStreamEnded(
        cancelled: Bool, stopped: Bool
    ) -> Bool {
        !cancelled && !stopped
    }

    private func handleChunk(_ raw: String) {
        let (chunk, live) = Self.parseFrame(raw)
        callbacks.onFrame(chunk, live)
    }

    /// A non-JSON body is treated as the chunk itself, and a missing `data` field falls back
    /// the same way — matching `terminalStream.ts`'s `try/catch` around `JSON.parse` rather
    /// than failing a frame outright just because its shape was unexpected. `nonisolated` and
    /// `static` because it is pure and worth testing without the streaming machinery around it.
    nonisolated static func parseFrame(_ raw: String) -> (chunk: String, live: Bool) {
        // `TerminalFrameEvent` owns the wire shape, including the rule that an absent or
        // malformed `live` means live. Decoding through it keeps that rule in one place; a second
        // copy here would be free to drift and nothing would notice which one was wrong.
        guard let jsonData = raw.data(using: .utf8),
            let event = try? JSONDecoder().decode(TerminalFrameEvent.self, from: jsonData)
        else {
            return (raw, true)
        }
        return (event.data, event.live)
    }

    /// See `PaiSseClient.startWatchdog()` — same mechanism, same interval, same reasoning.
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
