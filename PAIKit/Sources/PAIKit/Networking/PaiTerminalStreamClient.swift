import Foundation

/// Swift port of `pai-cloud/web/src/api/terminalStream.ts`. Deliberately not `PaiSseClient`: no
/// cursor, no replay — a terminal is a raw live view, not a resumable log — and a different
/// backoff. See that type's doc comment for why this authenticates natively via
/// `PaiRequestFactory` instead of the web's cookie.
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

    private let sessionId: String
    private let requestFactory: PaiRequestFactory
    private let urlSession: URLSession
    private let callbacks: Callbacks

    private var backoffNanos = PaiTerminalStreamClient.initialBackoffNanos
    private var stopped = false
    private var streamTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    public init(
        sessionId: String,
        requestFactory: PaiRequestFactory,
        callbacks: Callbacks,
        urlSession: URLSession = .shared
    ) {
        self.sessionId = sessionId
        self.requestFactory = requestFactory
        self.callbacks = callbacks
        self.urlSession = urlSession
    }

    public func connect() {
        guard !stopped else { return }
        reconnectTask?.cancel()
        streamTask?.cancel()
        streamTask = Task { await self.runConnection() }
    }

    public func disconnect() {
        stopped = true
        reconnectTask?.cancel()
        streamTask?.cancel()
        callbacks.onDisconnected()
    }

    private func runConnection() async {
        guard let request = try? requestFactory.makeRequest(path: "/api/session/\(sessionId)/terminal") else {
            handleDisconnect()
            return
        }

        do {
            let (bytes, response) = try await urlSession.bytes(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                handleDisconnect()
                return
            }

            backoffNanos = Self.initialBackoffNanos
            callbacks.onConnected()

            var dataLines: [String] = []

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                if line.isEmpty {
                    if !dataLines.isEmpty {
                        // Named `frame` events and a backend falling back to unnamed `message`
                        // events are handled identically — `terminalStream.ts` wires both to
                        // the same handler, so the event name itself is never branched on.
                        handleChunk(dataLines.joined(separator: "\n"))
                    }
                    dataLines = []
                    continue
                }
                if line.hasPrefix("data:") {
                    dataLines.append(Self.sseDataValue(from: line.dropFirst("data:".count)))
                }
                // `event:` is read but not branched on, per the comment above; other fields are unused.
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
    /// double-reconnect bug, this client's own copy since it has no watchdog to trigger it via,
    /// but the same race exists whenever `connect()` cancels a still-running `streamTask`.
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
        guard let jsonData = raw.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let data = parsed["data"] as? String
        else {
            return (raw, true)
        }
        let live = parsed["live"] as? Bool ?? true
        return (data, live)
    }

    private func handleDisconnect() {
        callbacks.onDisconnected()
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        streamTask?.cancel()
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
