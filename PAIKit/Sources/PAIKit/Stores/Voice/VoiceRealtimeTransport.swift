import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What `VoiceRecordingSession` needs from a live socket to ElevenLabs' realtime endpoint,
/// abstracted so the state machine driving it is testable against a scripted fake instead of a
/// real connection — the same reason `ingestLevel`/`ingestAudioChunk` take plain values rather
/// than reading a microphone. `URLSessionVoiceRealtimeTransport` is the production
/// implementation; unlike the rest of this file, its own behaviour against a live socket is
/// unverified by anything in this package — see the `ios` skill on why (compiles for free here,
/// proven live only on a `Mac` run).
public protocol VoiceRealtimeTransport: Sendable {
    func connect(url: URL) async throws
    func send(text: String) async throws
    /// One message per call — the caller loops. Throws when the connection ends, rather than
    /// returning `nil`, so the loop's `catch` is the single place a lost connection is handled.
    func receive() async throws -> String
    func close(code: Int, reason: String?) async
}

public enum VoiceTransportError: Error, Sendable, Equatable {
    case notConnected
    /// `receive()` failed — a dropped socket, a server-initiated close, or a plain network
    /// error. `reason` carries the close reason text when the transport actually got one (a
    /// clean server close, e.g. ElevenLabs' `resource_exhausted`); `nil` for everything else,
    /// including the far more common case of a phone simply losing signal mid-take, which is
    /// exactly the scenario `VoiceRecordingSession`'s reconnect logic exists to survive.
    case connectionLost(reason: String?)
}

/// `URLSessionWebSocketTask`-backed. ElevenLabs is a third party the app talks to directly —
/// deliberately outside `PaiRequestFactory`'s reach, which owns only the PAI backend's base URL
/// and bearer auth and has no opinion on this host or its query-param token. An `actor` rather
/// than a lock-guarded class: `Sendable` conformance falls out of actor isolation instead of a
/// manually-audited `@unchecked`.
public actor URLSessionVoiceRealtimeTransport: VoiceRealtimeTransport {
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(url: URL) async throws {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
    }

    public func send(text: String) async throws {
        guard let task else { throw VoiceTransportError.notConnected }
        try await task.send(.string(text))
    }

    public func receive() async throws -> String {
        guard let task else { throw VoiceTransportError.notConnected }
        do {
            switch try await task.receive() {
            case let .string(text): return text
            case let .data(data): return String(decoding: data, as: UTF8.self)
            @unknown default: return ""
            }
        } catch {
            // Populated only for a clean server-initiated close; a plain network failure leaves
            // `closeCode` at `.invalid` and this stays `nil` — the caller treats that as "unknown
            // cause, assume transient" rather than as "no close happened at all".
            let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) }
            throw VoiceTransportError.connectionLost(reason: reason)
        }
    }

    public func close(code: Int, reason: String?) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.flatMap { Data($0.utf8) })
        task = nil
    }
}

/// Android's ported, hard-won behaviour: ElevenLabs closes the realtime socket with reason
/// `resource_exhausted` under load, and the web has no reconnect at all for it — a lost
/// connection there just ends the take. This is the pure decision of whether and how long to
/// wait before trying again; `VoiceRecordingSession` does not currently call it, because
/// wiring an actual reconnect (re-mint a token, reconnect, resend
/// buffered audio, concatenate transcripts across the two connections) was left for a follow-up
/// rather than folded into an already-large state machine half-tested.
public enum ReconnectPolicy {
    /// Seconds, ported from Android; the last delay repeats for any attempt past the array's
    /// length, up to `maxAttempts`.
    public static let backoffSeconds = [5, 10, 20]
    public static let maxAttempts = 5

    public static func shouldReconnect(closeReason: String?) -> Bool {
        closeReason?.contains("resource_exhausted") ?? false
    }

    /// `nil` once `maxAttempts` is exceeded — the caller gives up and reports connection loss.
    public static func delaySeconds(forAttempt attempt: Int) -> Int? {
        guard attempt >= 1, attempt <= maxAttempts else { return nil }
        let index = min(attempt, backoffSeconds.count) - 1
        return backoffSeconds[index]
    }
}
