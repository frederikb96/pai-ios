import Foundation

/// Builds every request the app sends.
///
/// pai-android constructs the `Authorization` header independently in three places — the REST
/// client, the transcript stream and the terminal stream — each carrying its own copy of the URL
/// scheme check. Three transports, three copies of the same two rules, and a change has to find
/// all three. This type exists so there is one.
public struct PaiRequestFactory: Sendable {

    public enum ConfigurationError: Error, Equatable {
        case emptyBaseURL
        case unsupportedScheme(String?)
        case malformedBaseURL
    }

    private let baseURL: URL
    private let tokenProvider: @Sendable () -> String?

    /// - Parameter tokenProvider: read at send time rather than captured, so a token entered or
    ///   changed in settings takes effect on the next request without rebuilding the client.
    public init(
        baseURL rawBaseURL: String,
        tokenProvider: @escaping @Sendable () -> String?
    ) throws {
        let trimmed = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ConfigurationError.emptyBaseURL }

        guard let url = URL(string: trimmed) else { throw ConfigurationError.malformedBaseURL }
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ConfigurationError.unsupportedScheme(url.scheme)
        }

        // A trailing slash would double up against the leading slash every path carries.
        let normalized = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        guard let normalizedURL = URL(string: normalized) else {
            throw ConfigurationError.malformedBaseURL
        }

        self.baseURL = normalizedURL
        self.tokenProvider = tokenProvider
    }

    public func makeRequest(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil,
        contentType: String? = nil
    ) throws -> URLRequest {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else {
            throw ConfigurationError.malformedBaseURL
        }
        if !query.isEmpty { components.queryItems = query }

        guard let url = components.url else { throw ConfigurationError.malformedBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if let token = tokenProvider(), !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}
