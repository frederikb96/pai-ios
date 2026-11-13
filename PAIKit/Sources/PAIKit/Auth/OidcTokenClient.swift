import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// What a sign-in leaves behind: the bearer every request carries, and the refresh token that
/// gets a new one when the backend refuses it.
public struct OidcTokenSet: Codable, Equatable, Sendable {
    public let accessToken: String
    /// `nil` when the provider issued none (no `offline_access`); such a sign-in cannot be renewed.
    public let refreshToken: String?

    public init(accessToken: String, refreshToken: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
    }
}

/// The token endpoint: trading an authorization code for tokens, and a refresh token for new ones.
public struct OidcTokenClient: Sendable {
    private let configuration: OidcConfiguration
    private let urlSession: URLSession

    public init(configuration: OidcConfiguration, urlSession: URLSession = .shared) {
        self.configuration = configuration
        self.urlSession = urlSession
    }

    public func exchange(code: String, for request: OidcAuthorizationRequest) async throws(OidcError) -> OidcTokenSet {
        try await post([
            "grant_type": "authorization_code",
            "client_id": configuration.clientId,
            "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString,
            "code_verifier": request.codeVerifier,
        ])
    }

    /// A renewal. The provider rotates the refresh token, and the new one replaces the old; one
    /// that answers without a refresh token leaves the old one standing.
    public func refresh(_ tokens: OidcTokenSet) async throws(OidcError) -> OidcTokenSet {
        guard let refreshToken = tokens.refreshToken else { throw .rejected("no refresh token") }
        let renewed = try await post([
            "grant_type": "refresh_token",
            "client_id": configuration.clientId,
            "refresh_token": refreshToken,
        ])
        return OidcTokenSet(accessToken: renewed.accessToken, refreshToken: renewed.refreshToken ?? refreshToken)
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
        }
    }

    private struct ErrorResponse: Decodable {
        let error: String
        let errorDescription: String?

        enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    private func post(_ form: [String: String]) async throws(OidcError) -> OidcTokenSet {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(form).utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw .unavailable(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw .unavailable("Response was not HTTP") }

        switch http.statusCode {
        case 200..<300:
            guard let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data),
                !tokens.accessToken.isEmpty
            else { throw .unavailable("unreadable token response") }
            return OidcTokenSet(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken)
        case 400..<500:
            let reason = (try? JSONDecoder().decode(ErrorResponse.self, from: data))
                .map { $0.errorDescription ?? $0.error }
            throw .rejected(reason ?? "HTTP \(http.statusCode)")
        default:
            throw .unavailable("HTTP \(http.statusCode)")
        }
    }

    /// `application/x-www-form-urlencoded`, escaping everything outside RFC 3986's unreserved set
    /// — a refresh token may carry `+` or `/`, which a looser set would let through as-is.
    static func formEncode(_ form: [String: String]) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var pairs: [String] = []
        for key in form.keys.sorted() {
            let value = form[key] ?? ""
            pairs.append("\(key)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)")
        }
        return pairs.joined(separator: "&")
    }
}
