import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

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
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ConfigurationError.malformedBaseURL
        }
        // `percentEncodedPath`, not `appendingPathComponent` — the latter treats its argument as
        // raw, unescaped text and re-encodes anything already percent-encoded in it. A caller
        // that needs one character escaped inside a single path segment (a draft key that may
        // contain `/`, see `PaiApiClient`) has to hand over an already-encoded path; passing that
        // through `appendingPathComponent` would turn its `%2F` into `%252F`.
        components.percentEncodedPath = baseURL.path + path
        if !query.isEmpty {
            components.queryItems = query
            // `+` is a legal literal character in a URL query per RFC 3986, so `URLComponents`
            // leaves one alone if a value contains it — but the backend parses the query as
            // `application/x-www-form-urlencoded`, where a literal `+` decodes to a space.
            // Escape it explicitly so a value that happens to contain one (a VM path, an
            // attachment filename) round-trips instead of silently becoming a space server-side.
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
        }

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
