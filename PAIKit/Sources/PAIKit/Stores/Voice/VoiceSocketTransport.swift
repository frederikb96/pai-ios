import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What `VoiceUplinkSession` needs from a live socket to PAI Cloud's `/api/voice/socket`,
/// abstracted the same way `VoiceRealtimeTransport` was for ElevenLabs — a state machine testable
/// against a scripted fake rather than a real connection. `URLSessionVoiceSocketTransport` is the
/// production implementation; like its predecessor, its own behaviour against a live socket is
/// unverified by anything in this package (proven only on a `Mac` run).
public protocol VoiceSocketTransportProtocol: Sendable {
    func connect(url: URL) async throws
    func send(_ frame: VoiceUpFrame) async throws
    func sendAudio(_ data: Data) async throws
    /// One message per call — the caller loops. Throws when the connection ends, rather than
    /// returning `nil`, so the loop's `catch` is the single place a lost connection is handled.
    func receive() async throws -> VoiceSocketMessage
    func close(code: Int, reason: String?) async
}

/// One decoded inbound frame — binary audio or a parsed JSON control message. A JSON message this
/// build cannot even parse into `VoiceDownFrame` is dropped by the transport itself (logged, never
/// surfaced) — indistinguishable from `.unrecognized` to the caller, since neither is actionable.
public enum VoiceSocketMessage: Sendable, Equatable {
    case control(VoiceDownFrame)
    case audio(ref: Int, pcm: Data)
}

public enum VoiceSocketTransportError: Error, Sendable, Equatable {
    case notConnected
    case connectionLost(reason: String?)
}

extension URLSessionWebSocketTask {
    /// A close code plus whatever reason text the server sent, when either is actually present —
    /// matches `URLSessionWebSocketTask.closeDescription` from the ElevenLabs-era transport,
    /// kept here since a dropped PAI Cloud socket carries the same shape.
    fileprivate var closeDescription: String? {
        let reasonText = closeReason.map { String(decoding: $0, as: UTF8.self) }
        guard closeCode != .invalid else { return reasonText }
        let codeText = "close \(closeCode.rawValue)"
        return reasonText.map { "\(codeText): \($0)" } ?? codeText
    }
}

/// `URLSessionWebSocketTask`-backed connection to PAI Cloud's own voice socket. Unlike the
/// ElevenLabs-era transport, this talks to the SAME backend every other request in this app
/// does — the caller is responsible for turning `PaiRequestFactory`'s base URL into a `ws(s)://`
/// one (`PaiRequestFactory.voiceSocketURL`), since auth here travels inside the `hello` frame
/// itself rather than as a header the handshake needs.
public actor URLSessionVoiceSocketTransport: VoiceSocketTransportProtocol {
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

    public func send(_ frame: VoiceUpFrame) async throws {
        guard let task else { throw VoiceSocketTransportError.notConnected }
        try await task.send(.string(try frame.encoded()))
    }

    public func sendAudio(_ data: Data) async throws {
        guard let task else { throw VoiceSocketTransportError.notConnected }
        try await task.send(.data(data))
    }

    public func receive() async throws -> VoiceSocketMessage {
        guard let task else { throw VoiceSocketTransportError.notConnected }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch {
            throw VoiceSocketTransportError.connectionLost(reason: task.closeDescription)
        }
        switch message {
        case let .data(data):
            guard let (ref, pcm) = VoiceSocketProtocol.unpackDownlinkAudio(data) else {
                throw VoiceSocketTransportError.connectionLost(reason: "malformed downlink audio frame")
            }
            return .audio(ref: ref, pcm: pcm)
        case let .string(text):
            guard let frame = VoiceDownFrame.decode(text) else {
                // Recurse rather than surface a decode failure as a connection error — an
                // unparseable text frame is not the socket dying, and the caller's `receive()`
                // loop should simply see the next real message.
                return try await receive()
            }
            return .control(frame)
        @unknown default:
            return try await receive()
        }
    }

    public func close(code: Int, reason: String?) async {
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure
        task?.cancel(with: closeCode, reason: reason.flatMap { Data($0.utf8) })
        task = nil
    }
}

extension PaiRequestFactory {
    /// `makeRequest`'s URL with the scheme swapped to `ws`/`wss` — what a
    /// `URLSessionWebSocketTask` needs for a backend endpoint that authenticates over the
    /// connection's own protocol (the `hello` frame's `auth` field) rather than a header the
    /// handshake would otherwise carry. Building this from `makeRequest` rather than duplicating
    /// its base-URL/path assembly is what keeps the guarantee this type exists for — one place
    /// owns the base URL — true for the voice socket too.
    public func voiceSocketURL() throws -> URL {
        let request = try makeRequest(path: "/api/voice/socket")
        guard let httpURL = request.url, var components = URLComponents(url: httpURL, resolvingAgainstBaseURL: false)
        else {
            throw ConfigurationError.malformedBaseURL
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw ConfigurationError.malformedBaseURL }
        return url
    }
}
