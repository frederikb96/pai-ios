import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What `SpeechOutputSession` needs from a live socket to ElevenLabs' multi-context TTS endpoint
/// — the same split `VoiceRealtimeTransport` draws for STT, and for the same reason: the queue
/// and context bookkeeping that drive it are testable against a scripted fake instead of a real
/// connection. `URLSessionVoiceTtsTransport` is the production implementation; like its STT
/// sibling, its own behaviour against a live socket is unverified by anything in this package —
/// see the `ios` skill on why (compiles for free here, proven live only on a `Mac` run).
public protocol VoiceTtsTransport: Sendable {
    func connect(url: URL) async throws
    func send(text: String) async throws
    /// One message per call — the caller loops. Throws when the connection ends, rather than
    /// returning `nil`, matching `VoiceRealtimeTransport.receive()`'s own contract.
    func receive() async throws -> String
    func close(code: Int, reason: String?) async
}

/// `URLSessionWebSocketTask`-backed, identical in shape to `URLSessionVoiceRealtimeTransport` —
/// ElevenLabs is a third party the app talks to directly, outside `PaiRequestFactory`'s reach.
/// `VoiceTransportError` (`VoiceRealtimeTransport.swift`) is reused rather than duplicated: both
/// transports fail in the same two ways, "never connected" and "the connection ended", and
/// neither is specific to STT.
public actor URLSessionVoiceTtsTransport: VoiceTtsTransport {
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
