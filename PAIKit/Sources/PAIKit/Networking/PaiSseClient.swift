import Foundation

/// Swift port of `pai-cloud/web/src/api/sse.ts` — the resumable transcript stream. The web
/// authenticates it with a cookie only because a browser `EventSource` cannot send headers;
/// `URLSession` can, so this client sends the same `Authorization` header as every other
/// request, through the same `PaiRequestFactory`. Do not carry the cookie assumption over.
///
/// `EventSource` has no Foundation equivalent, so this parses the `text/event-stream` framing
/// (`event:` / `data:` lines, a blank line as the record terminator) by hand over
/// `URLSession.bytes(for:)`.
///
/// `@MainActor`-isolated rather than protected with locks: every caller is UI-driven (a chat
/// view model deciding when to (re)connect), every callback exists to update UI state, and the
/// stream's own event rate is far below anything that would make hopping onto the main actor
/// per line a real cost.
@MainActor
public final class PaiSseClient {

    /// Every closure is `@MainActor` as well as `@Sendable` — `PaiSseClient` itself is
    /// `@MainActor`, and every realistic caller is a `@MainActor` view model, so a plain
    /// `@Sendable` closure here would force `MainActor.assumeIsolated` boilerplate at every
    /// wiring site just to hand over a closure that is already main-actor-isolated in practice.
    public struct Callbacks: Sendable {
        public var onInit: @MainActor @Sendable (SseInitEvent) -> Void
        public var onBatch: @MainActor @Sendable (SseBatchEvent) -> Void
        public var onStatus: @MainActor @Sendable (SseStatusEvent) -> Void
        public var onConnected: @MainActor @Sendable () -> Void
        public var onDisconnected: @MainActor @Sendable () -> Void

        public init(
            onInit: @escaping @MainActor @Sendable (SseInitEvent) -> Void,
            onBatch: @escaping @MainActor @Sendable (SseBatchEvent) -> Void,
            onStatus: @escaping @MainActor @Sendable (SseStatusEvent) -> Void,
            onConnected: @escaping @MainActor @Sendable () -> Void,
            onDisconnected: @escaping @MainActor @Sendable () -> Void
        ) {
            self.onInit = onInit
            self.onBatch = onBatch
            self.onStatus = onStatus
            self.onConnected = onConnected
            self.onDisconnected = onDisconnected
        }
    }

    private static let initialBackoffNanos: UInt64 = 2_000_000_000
    private static let maxBackoffNanos: UInt64 = 30_000_000_000
    private static let staleTimeout: TimeInterval = 45
    private static let watchdogIntervalNanos: UInt64 = 10_000_000_000
    private static let terminalStatuses: Set<SessionStatus> = [.completed, .deleted]

    private let sessionId: String
    private let requestFactory: PaiRequestFactory
    private let urlSession: URLSession
    private let callbacks: Callbacks

    private var cursor: Int?
    private var backoffNanos = PaiSseClient.initialBackoffNanos
    private var lastEventTime = Date()
    private var stopped = false
    private var terminal = false
    private var streamTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    public init(
        sessionId: String,
        requestFactory: PaiRequestFactory,
        callbacks: Callbacks,
        initialCursor: Int? = nil,
        urlSession: URLSession = .shared
    ) {
        self.sessionId = sessionId
        self.requestFactory = requestFactory
        self.callbacks = callbacks
        self.cursor = initialCursor
        self.urlSession = urlSession
    }

    public func connect() {
        guard !stopped, !terminal else { return }
        reconnectTask?.cancel()
        streamTask?.cancel()
        streamTask = Task { await self.runConnection() }
    }

    public func disconnect() {
        stopped = true
        reconnectTask?.cancel()
        streamTask?.cancel()
        watchdogTask?.cancel()
        callbacks.onDisconnected()
    }

    private func runConnection() async {
        var query: [URLQueryItem] = []
        if let cursor { query.append(URLQueryItem(name: "Last-Event-ID", value: String(cursor))) }

        guard let request = try? requestFactory.makeRequest(path: "/api/session/\(sessionId)/stream", query: query)
        else {
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
            lastEventTime = Date()
            callbacks.onConnected()
            startWatchdog()

            var eventName: String?
            var dataLines: [String] = []

            for try await line in bytes.lines {
                if Task.isCancelled || terminal { break }
                if line.isEmpty {
                    if let name = eventName, !dataLines.isEmpty {
                        handleEvent(name: name, data: dataLines.joined(separator: "\n"))
                    }
                    eventName = nil
                    dataLines = []
                    continue
                }
                if line.hasPrefix("event:") {
                    eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                } else if line.hasPrefix("data:") {
                    dataLines.append(Self.sseDataValue(from: line.dropFirst("data:".count)))
                }
                // Any other field (id:, retry:, comments) goes unused by this stream, same as the web client.
            }

            if Self.shouldReconnectAfterStreamEnded(
                cancelled: Task.isCancelled, terminal: terminal, stopped: stopped
            ) {
                handleDisconnect()
            }
        } catch {
            if Self.shouldReconnectAfterStreamEnded(
                cancelled: Task.isCancelled, terminal: terminal, stopped: stopped
            ) {
                handleDisconnect()
            }
        }
    }

    /// Per the SSE spec, at most one leading space after `data:` is stripped — the rest of the
    /// line, including any other leading or trailing whitespace, is data. `.trimmingCharacters`
    /// over-strips; JSON payloads survive that by luck (whitespace outside string literals is
    /// insignificant), but it is wrong on principle for a framing rule that events beyond JSON
    /// can carry through this same parser.
    nonisolated static func sseDataValue(from line: Substring) -> String {
        line.first == " " ? String(line.dropFirst()) : String(line)
    }

    /// Whether the read loop ending unexpectedly should trigger a reconnect. `cancelled` is the
    /// case that matters: the watchdog reconnects by cancelling `streamTask`, whose own `for try
    /// await` then unwinds into this same exit path — reacting to that unwind as *another*
    /// disconnect scheduled a second reconnect on top of the one `scheduleReconnect()` already
    /// started. `nonisolated static` so the rule is testable without the streaming machinery.
    nonisolated static func shouldReconnectAfterStreamEnded(
        cancelled: Bool, terminal: Bool, stopped: Bool
    ) -> Bool {
        !cancelled && !terminal && !stopped
    }

    private func handleEvent(name: String, data: String) {
        lastEventTime = Date()
        guard let jsonData = data.data(using: .utf8) else { return }

        switch name {
        case "init":
            guard let event = try? JSONDecoder().decode(SseInitEvent.self, from: jsonData) else { return }
            if let newCursor = event.cursor { cursor = newCursor }
            callbacks.onInit(event)

        case "batch":
            guard let event = try? JSONDecoder().decode(SseBatchEvent.self, from: jsonData) else { return }
            if let maxId = event.entries.map(\.id).max() { cursor = maxId }
            callbacks.onBatch(event)

        case "status":
            guard let event = try? JSONDecoder().decode(SseStatusEvent.self, from: jsonData) else { return }
            callbacks.onStatus(event)
            if Self.terminalStatuses.contains(event.status) {
                terminal = true
                disconnect()
            }

        case "processing", "ping":
            break  // No-op handlers that exist only to advance `lastEventTime`, already done above.

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
        watchdogTask?.cancel()
        guard !stopped, !terminal else { return }

        let delay = backoffNanos
        backoffNanos = min(backoffNanos * 2, Self.maxBackoffNanos)

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self, !Task.isCancelled else { return }
            self.connect()
        }
    }
}
