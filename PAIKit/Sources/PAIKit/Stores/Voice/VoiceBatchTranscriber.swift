import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Re-transcribes a stored recording from its raw capture — `POST
/// https://api.elevenlabs.io/v1/speech-to-text?token=...`, `multipart/form-data`. Separate from
/// `VoiceRealtimeTransport`: this is a single request/response call, not a streaming connection,
/// so it uses `URLSession.data(for:)` directly rather than needing a protocol seam — the same
/// reasoning `PaiApiClient` already applies, and the same reason it is testable with a stub
/// `URLProtocol` instead of a live call.
public struct VoiceBatchTranscriber: Sendable {
    /// Distinct from `VoiceRealtimeProtocol.modelId` — the batch model accepts any input rate,
    /// which is the entire reason a recording's untouched raw capture is worth keeping.
    public static let modelId = "scribe_v2"

    private let urlSession: URLSession

    public init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    public enum Result: Sendable, Equatable {
        case text(String)
        /// An empty `text` in an otherwise-successful response — the caller shows this
        /// distinctly from a transport failure, since retrying will not fix silence.
        case noSpeechDetected
        case failed(PaiError)
    }

    public func transcribe(wav: Data, token: String, language: VoiceSettings.Language) async throws -> Result {
        let boundary = "PAIKit-\(UUID().uuidString)"
        let body = Self.multipartBody(wav: wav, language: language, boundary: boundary)

        var components = URLComponents(string: "https://api.elevenlabs.io/v1/speech-to-text")
        components?.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components?.url else { throw VoiceTransportError.notConnected }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return .failed(.transport("Response was not HTTP"))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(.from(statusCode: http.statusCode, body: data))
        }

        struct ResponseBody: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data), !decoded.text.isEmpty else {
            return .noSpeechDetected
        }
        return .text(decoded.text)
    }

    /// Pure body construction — testable without a network call. `language_code` is omitted for
    /// `.auto`, matching `VoiceRealtimeProtocol.connectionURL`'s reasoning. Internal rather than
    /// `private` so `VoiceBatchTranscriberTests` can assert its shape directly instead of
    /// reaching it only through a stubbed round trip.
    static func multipartBody(wav: Data, language: VoiceSettings.Language, boundary: String) -> Data {
        var body = Data()
        func appendField(name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append(value.data(using: .utf8)!)
            body.append("\r\n".data(using: .utf8)!)
        }
        appendField(name: "model_id", value: modelId)
        if language != .auto {
            appendField(name: "language_code", value: language.rawValue)
        }
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"recording.wav\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return body
    }
}
