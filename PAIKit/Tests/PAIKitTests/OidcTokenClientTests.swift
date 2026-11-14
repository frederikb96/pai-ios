import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The token endpoint as the provider answers it: what goes out, and which answers sign out
/// (a refusal) as against which only fail this attempt (the provider unreachable).
final class OidcTokenClientTests: XCTestCase {

    private let configuration = OidcConfiguration(
        issuer: URL(string: "https://login.example.invalid")!,
        clientId: "client-1",
        redirectURI: URL(string: "pai://oauth/callback")!,
        scopes: ["openid"]
    )

    private func client(status: Int, body: String) -> OidcTokenClient {
        PaiStubURLProtocol.reset()
        PaiStubURLProtocol.stub = PaiStubURLProtocol.Stub(
            statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        return OidcTokenClient(configuration: configuration, urlSession: PaiStubURLProtocol.makeSession())
    }

    /// Decoded the way the provider decodes a form body, where a literal `+` is a space.
    private func sentForm() throws -> [String: String] {
        let body = String(decoding: try XCTUnwrap(PaiStubURLProtocol.capturedBody), as: UTF8.self)
        let pairs = body.split(separator: "&").map { pair -> (String, String) in
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? ""
            }
            return (parts[0], parts.count > 1 ? parts[1] : "")
        }
        return Dictionary(uniqueKeysWithValues: pairs)
    }

    func testSignOutRevokesTheRefreshTokenAtTheProvider() async throws {
        let client = client(status: 200, body: "")

        try await client.revoke(OidcTokenSet(accessToken: "a1", refreshToken: "r+1"))

        let request = try XCTUnwrap(PaiStubURLProtocol.capturedRequest)
        XCTAssertEqual(request.url?.path, "/oauth/v2/revoke")
        XCTAssertEqual(request.httpMethod, "POST")
        let form = try sentForm()
        XCTAssertEqual(form["token"], "r+1")
        XCTAssertEqual(form["token_type_hint"], "refresh_token")
        XCTAssertEqual(form["client_id"], "client-1")
    }

    func testSignOutWithoutARefreshTokenRevokesTheAccessToken() async throws {
        let client = client(status: 200, body: "")

        try await client.revoke(OidcTokenSet(accessToken: "a1", refreshToken: nil))

        let form = try sentForm()
        XCTAssertEqual(form["token"], "a1")
        XCTAssertEqual(form["token_type_hint"], "access_token")
    }

    func testARefusedRevocationThrowsForTheCallerToIgnore() async {
        let client = client(status: 503, body: "")
        do {
            try await client.revoke(OidcTokenSet(accessToken: "a1", refreshToken: "r1"))
            XCTFail("expected an error")
        } catch {
            guard case .unavailable = error else { return XCTFail("\(error)") }
        }
    }

    func testTheExchangeSendsTheVerifierOfItsOwnAttempt() async throws {
        let client = client(status: 200, body: #"{"access_token":"a1","refresh_token":"r1","token_type":"Bearer"}"#)
        let request = OidcAuthorizationRequest(configuration: configuration)

        let tokens = try await client.exchange(code: "c1", for: request)

        XCTAssertEqual(tokens, OidcTokenSet(accessToken: "a1", refreshToken: "r1"))
        let form = try sentForm()
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "c1")
        XCTAssertEqual(form["code_verifier"], request.codeVerifier)
        XCTAssertEqual(PaiStubURLProtocol.capturedRequest?.url?.path, "/oauth/v2/token")
    }

    /// A refresh token is opaque and may hold `+`, `/` or `=`; sent unescaped in a form body, a
    /// `+` arrives as a space and the provider refuses it, which signs the app out.
    func testARefreshTokenSurvivesTheFormEncoding() async throws {
        let client = client(status: 200, body: #"{"access_token":"a2","refresh_token":"r2"}"#)
        _ = try await client.refresh(OidcTokenSet(accessToken: "a1", refreshToken: "r+1/x=="))
        let form = try sentForm()
        XCTAssertEqual(form["refresh_token"], "r+1/x==")
        XCTAssertEqual(form["grant_type"], "refresh_token")
    }

    func testARefreshWithoutANewRefreshTokenKeepsTheOldOne() async throws {
        let client = client(status: 200, body: #"{"access_token":"a2"}"#)
        let renewed = try await client.refresh(OidcTokenSet(accessToken: "a1", refreshToken: "r1"))
        XCTAssertEqual(renewed, OidcTokenSet(accessToken: "a2", refreshToken: "r1"))
    }

    /// The shape Zitadel answers a dead refresh token with.
    func testARefusalIsRejectedWithTheProvidersReason() async {
        let client = client(
            status: 400, body: #"{"error":"invalid_request","error_description":"Errors.User.RefreshToken.Invalid"}"#)
        do {
            _ = try await client.refresh(OidcTokenSet(accessToken: "a1", refreshToken: "r1"))
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error, .rejected("Errors.User.RefreshToken.Invalid"))
        }
    }

    /// An outage at the provider must not read as a dead credential.
    func testAServerErrorIsUnavailableNotRejected() async {
        let client = client(status: 503, body: "upstream down")
        do {
            _ = try await client.refresh(OidcTokenSet(accessToken: "a1", refreshToken: "r1"))
            XCTFail("expected a failure")
        } catch {
            guard case .unavailable = error else { return XCTFail("got \(error)") }
        }
    }
}
