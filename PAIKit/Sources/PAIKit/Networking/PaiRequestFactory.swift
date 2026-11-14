import Foundation

// URLSession and friends live in FoundationNetworking on Linux, where the free CI runner builds
// this package. On Apple platforms the module does not exist and Foundation already has them.
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Builds every request the app sends.
///
/// Three transports — the REST client, the transcript stream and the terminal stream — share the
/// `Authorization` and device-name headers and the URL scheme check. They are built here once, so a change to either
/// rule is made in one place.
public struct PaiRequestFactory: Sendable {

    public enum ConfigurationError: Error, Equatable {
        case emptyBaseURL
        case unsupportedScheme(String?)
        case malformedBaseURL
    }

    private let baseURL: URL
    private let deviceName: String
    private let tokenProvider: @Sendable () -> String?

    /// - Parameter deviceName: the user-visible name of this device, sent on every request so the
    ///   server's list of signed-in devices can show which one a session belongs to.
    /// - Parameter tokenProvider: read at send time rather than captured, so a token entered or
    ///   changed in settings takes effect on the next request without rebuilding the client.
    public init(
        baseURL rawBaseURL: String,
        deviceName: String,
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
        self.deviceName = DeviceName.header(for: deviceName)
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
        request.setValue(deviceName, forHTTPHeaderField: DeviceName.headerField)

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return reauthorized(request)
    }

    /// The request carrying the token as it is now, for sending again after the credential was
    /// renewed.
    public func reauthorized(_ request: URLRequest) -> URLRequest {
        var request = request
        let token = tokenProvider().flatMap { $0.isEmpty ? nil : $0 }
        request.setValue(token.map { "Bearer \($0)" }, forHTTPHeaderField: "Authorization")
        return request
    }

    /// The bearer a request was sent with — what a renewal is asked to replace.
    static func bearerToken(of request: URLRequest) -> String? {
        guard let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ")
        else { return nil }
        return String(header.dropFirst("Bearer ".count))
    }
}
