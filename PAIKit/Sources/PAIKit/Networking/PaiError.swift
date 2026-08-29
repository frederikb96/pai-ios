import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The backend's error contract is exactly one field: `{ "detail": String }`.
///
/// The web client throws `new Error(error.detail)` and every catch site surfaces that string
/// directly to the user, falling back to the status line when the body is not JSON. Reproducing
/// that shape here means error text matches across clients without a second translation layer.
public enum PaiError: Error, Equatable {
    /// The server answered with a JSON body carrying `detail`.
    case detail(String, statusCode: Int)
    /// The server answered with a non-JSON body; the status line is all there is.
    case http(statusCode: Int, reason: String)
    case transport(String)
    case decoding(String)

    /// What the user should see. Always non-empty.
    public var userMessage: String {
        switch self {
        case let .detail(text, _): return text
        case let .http(code, reason): return "HTTP \(code): \(reason)"
        case let .transport(text): return text
        case let .decoding(text): return text
        }
    }

    /// `409 session_not_active` on a send is a resume-and-retry signal rather than a failure.
    /// The pod handles the resume; the client only needs to avoid presenting it as a hard error.
    public var isSessionNotActive: Bool {
        if case let .detail(text, code) = self {
            return code == 409 && text.contains("session_not_active")
        }
        return false
    }
}

private struct ErrorBody: Decodable {
    let detail: String
}

extension PaiError {
    /// Build from a response the transport already has in hand.
    public static func from(statusCode: Int, body: Data) -> PaiError {
        if let parsed = try? JSONDecoder().decode(ErrorBody.self, from: body),
            !parsed.detail.isEmpty
        {
            return .detail(parsed.detail, statusCode: statusCode)
        }
        return .http(
            statusCode: statusCode,
            reason: HTTPURLResponse.localizedString(forStatusCode: statusCode)
        )
    }
}
