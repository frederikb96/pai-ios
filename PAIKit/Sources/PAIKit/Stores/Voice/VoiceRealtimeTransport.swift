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
    /// error. `reason` carries whatever `URLSessionWebSocketTask.closeDescription` below found —
    /// a numeric close code, the server's own reason text, or both; `nil` for everything else,
    /// including the far more common case of a phone simply losing signal mid-take, which is
    /// exactly the scenario `VoiceRecordingSession`'s reconnect logic exists to survive.
    case connectionLost(reason: String?)
}

extension URLSessionWebSocketTask {
    /// A close code plus whatever reason text the server sent, when either is actually present.
    /// Folds the numeric code in specifically so a handshake refusal — ElevenLabs closing with
    /// 1002 and never sending the 101 that would have opened the socket — reads differently in
    /// the log from an ordinary mid-stream drop, rather than both collapsing into the same
    /// `connectionLost(reason: nil)`. `nil` only when the task never received a close frame at
    /// all (`.invalid`) and sent no reason text either — a plain network failure.
    var closeDescription: String? {
        let reasonText = closeReason.map { String(decoding: $0, as: UTF8.self) }
        guard closeCode != .invalid else { return reasonText }
        let codeText = "close \(closeCode.rawValue)"
        return reasonText.map { "\(codeText): \($0)" } ?? codeText
    }
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
            throw VoiceTransportError.connectionLost(reason: task.closeDescription)
        }
    }

    public func close(code: Int, reason: String?) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.flatMap { Data($0.utf8) })
        task = nil
    }
}

/// How long `VoiceRecordingSession` waits before each attempt to reopen a lost realtime socket.
/// Every close during a take is retried, whatever its reason: ElevenLabs closes a healthy take
/// under load (`resource_exhausted`), at a session time limit and when it has heard nothing for
/// a while, and a phone losing signal carries no reason at all. The failures a retry cannot fix
/// arrive as an error message before the close and end transcription attempts there instead of
/// retrying — see `RealtimeDownlinkMessage` and `VoiceRecordingState.transcriptionStopped`.
///
/// No attempt limit: over the length of a take this pipeline is built for — an hour in a pocket —
/// a cellular handoff or a dead patch of signal is ordinary, not exceptional, and nothing about a
/// retry count should be the reason a take ends. The delay grows then holds at its ceiling for as
/// long as the take keeps running.
public enum ReconnectPolicy {
    /// Seconds. The last value repeats for any attempt past the array's length.
    public static let backoffSeconds = [2, 4, 8, 16, 30]

    public static func delaySeconds(forAttempt attempt: Int) -> Int {
        let index = min(max(attempt, 1), backoffSeconds.count) - 1
        return backoffSeconds[index]
    }
}
