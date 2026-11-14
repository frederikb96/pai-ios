import Foundation

/// Where and as what the app signs in: a public OIDC client (no secret, PKCE instead) at one
/// issuer.
///
/// The endpoint paths are Zitadel's, as its discovery document publishes them; they are fixed
/// rather than discovered so signing in costs one round trip fewer and fails the same way
/// offline as everything else does.
public struct OidcConfiguration: Sendable, Equatable {
    public let issuer: URL
    public let clientId: String
    public let redirectURI: URL
    public let scopes: [String]

    public init(issuer: URL, clientId: String, redirectURI: URL, scopes: [String]) {
        self.issuer = issuer
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scopes = scopes
    }

    public var authorizationEndpoint: URL { issuer.appendingPathComponent("oauth/v2/authorize") }
    public var tokenEndpoint: URL { issuer.appendingPathComponent("oauth/v2/token") }
    public var revocationEndpoint: URL { issuer.appendingPathComponent("oauth/v2/revoke") }

    /// What the web authentication session waits for: the redirect URI's scheme.
    public var callbackScheme: String { redirectURI.scheme ?? "" }
}

/// Why a sign-in or a renewal did not produce tokens.
public enum OidcError: Error, Equatable, Sendable {
    /// The redirect did not come back to this client's redirect URI.
    case unexpectedCallback
    /// The callback's `state` is not the one this attempt sent: an answer to some other attempt.
    case stateMismatch
    /// The identity provider declined, with its own reason.
    case denied(String)
    /// The token endpoint answered with a refusal (4xx): the code or refresh token is no good.
    case rejected(String)
    /// The token endpoint could not be reached or failed on its side; trying again may work.
    case unavailable(String)

    public var userMessage: String {
        switch self {
        case .unexpectedCallback: "The sign-in came back somewhere unexpected. Try again."
        case .stateMismatch: "The sign-in answer did not match this attempt. Try again."
        case .denied(let reason): "Sign-in was declined: \(reason)"
        case .rejected(let reason): "The sign-in was refused: \(reason)"
        case .unavailable(let reason): "The sign-in service could not be reached: \(reason)"
        }
    }
}

/// One authorization-code attempt with PKCE (RFC 7636, `S256`).
///
/// The verifier and `state` live exactly as long as the attempt: the verifier goes to the token
/// endpoint with the code, and `state` ties the callback to the URL this attempt opened.
public struct OidcAuthorizationRequest: Sendable {
    public let configuration: OidcConfiguration
    public let codeVerifier: String
    public let state: String

    public init(
        configuration: OidcConfiguration,
        codeVerifier: String = OidcAuthorizationRequest.randomToken(),
        state: String = OidcAuthorizationRequest.randomToken()
    ) {
        self.configuration = configuration
        self.codeVerifier = codeVerifier
        self.state = state
    }

    /// `BASE64URL(SHA256(verifier))`, unpadded.
    public var codeChallenge: String {
        Self.base64URL(Sha256.digest(Array(codeVerifier.utf8)))
    }

    public var url: URL {
        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientId),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI.absoluteString),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        return components.url!
    }

    /// The authorization code carried by the redirect, once the redirect is shown to belong to
    /// this attempt.
    public func authorizationCode(from callback: URL) throws(OidcError) -> String {
        let expected = configuration.redirectURI
        guard callback.scheme?.lowercased() == expected.scheme?.lowercased(),
            callback.host?.lowercased() == expected.host?.lowercased(),
            callback.path == expected.path,
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems
        else { throw .unexpectedCallback }

        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // An error answer is checked before `state`: the provider echoes `state` there too, and
        // its reason is the more useful thing to show.
        if let error = value("error") {
            throw .denied(value("error_description") ?? error)
        }
        guard value("state") == state else { throw .stateMismatch }
        guard let code = value("code") else { throw .unexpectedCallback }
        return code
    }

    /// 32 random bytes as unpadded base64url: 43 characters, the length RFC 7636 recommends for a
    /// verifier. `SystemRandomNumberGenerator` is the platform's cryptographic source on both
    /// Apple platforms and Linux.
    public static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return base64URL((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
