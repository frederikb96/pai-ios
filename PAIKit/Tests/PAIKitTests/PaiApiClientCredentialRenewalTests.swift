import Foundation
import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A refused credential is renewed and the request sent again before anyone sees the refusal;
/// only a credential that cannot be renewed signs out.
final class PaiApiClientCredentialRenewalTests: XCTestCase {

    /// A backend that accepts one bearer and refuses every other with `refusal`.
    private func client(
        accepting accepted: String,
        refusal: BearerStubURLProtocol.Refusal = .unauthorized,
        renewal: CredentialRenewal,
        failures: FailureCounter
    ) -> (PaiApiClient, TokenHolder) {
        BearerStubURLProtocol.configure(accepting: accepted, refusal: refusal)
        let holder = TokenHolder("old")
        let factory = try! PaiRequestFactory(
            baseURL: "https://example.invalid", deviceName: "Test iPhone", tokenProvider: { holder.token })
        let client = PaiApiClient(
            requestFactory: factory,
            urlSession: BearerStubURLProtocol.makeSession(),
            onAuthenticationFailure: { _ in failures.increment() },
            renewCredential: { _ in
                if renewal == .renewed { holder.token = "fresh" }
                return renewal
            }
        )
        return (client, holder)
    }

    func testARenewedCredentialRetriesTheRequestWithoutSigningOut() async throws {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "fresh", renewal: .renewed, failures: failures)

        let page = try await client.getSessions()

        XCTAssertEqual(page.sessions.count, 0)
        XCTAssertEqual(BearerStubURLProtocol.bearers, ["old", "fresh"])
        XCTAssertEqual(failures.count, 0)
    }

    /// The ingress proxy refuses a bad bearer with a plain-text 403, not a 401.
    func testTheProxys403IsRenewedLikeA401() async throws {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "fresh", refusal: .proxyForbidden, renewal: .renewed, failures: failures)

        _ = try await client.getSessions()

        XCTAssertEqual(BearerStubURLProtocol.bearers, ["old", "fresh"])
        XCTAssertEqual(failures.count, 0)
    }

    /// pai-cloud's own JSON 403 refuses the person, not the token: renewing would change nothing.
    func testARefusalOfThePersonIsNotRenewed() async {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "nobody", refusal: .appForbidden, renewal: .renewed, failures: failures)

        _ = try? await client.getSessions()

        XCTAssertEqual(BearerStubURLProtocol.bearers, ["old"])
        XCTAssertEqual(failures.count, 0)
    }

    /// A revoked device is refused for the device, not the token: renewing would only repeat the
    /// refusal, so the session ends at once and the person is told why.
    func testARevokedDeviceSignsOutWithoutRenewing() async {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "fresh", refusal: .deviceRevoked, renewal: .renewed, failures: failures)

        do {
            _ = try await client.getSessions()
            XCTFail("expected an error")
        } catch let error as PaiError {
            XCTAssertTrue(error.isDeviceRevoked)
            XCTAssertEqual(error.userMessage, "This device was signed out")
        } catch {
            XCTFail("\(error)")
        }

        XCTAssertEqual(BearerStubURLProtocol.bearers, ["old"])
        XCTAssertEqual(failures.count, 1)
    }

    func testACredentialThatCannotBeRenewedSignsOut() async {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "fresh", renewal: .rejected, failures: failures)

        _ = try? await client.getSessions()

        XCTAssertEqual(BearerStubURLProtocol.bearers, ["old"])
        XCTAssertEqual(failures.count, 1)
    }

    /// A renewed token the backend still refuses signs out after one retry rather than looping.
    func testARenewedTokenThatIsAlsoRefusedSignsOutAfterOneRetry() async {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "nobody", renewal: .renewed, failures: failures)

        _ = try? await client.getSessions()

        XCTAssertEqual(BearerStubURLProtocol.bearers, ["old", "fresh"])
        XCTAssertEqual(failures.count, 1)
    }

    /// The identity provider being unreachable is a failed request, never a sign-out.
    func testAnUnreachableProviderFailsTheRequestAndKeepsTheSignIn() async {
        let failures = FailureCounter()
        let (client, _) = client(accepting: "fresh", renewal: .unavailable("offline"), failures: failures)

        do {
            _ = try await client.getSessions()
            XCTFail("expected a failure")
        } catch {
            guard case .transport = error as? PaiError else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(failures.count, 0)
    }
}

/// Answers `[]` to the accepted bearer and `refusal` to any other, recording the bearer of every
/// request in order.
final class BearerStubURLProtocol: URLProtocol {
    enum Refusal {
        case unauthorized
        case proxyForbidden
        case appForbidden
        case deviceRevoked
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var accepted = ""
    nonisolated(unsafe) private static var refusal = Refusal.unauthorized
    nonisolated(unsafe) private static var seen: [String?] = []

    static func configure(accepting token: String, refusal: Refusal) {
        lock.lock()
        defer { lock.unlock() }
        accepted = token
        self.refusal = refusal
        seen = []
    }

    static var bearers: [String?] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BearerStubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let bearer = request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
        Self.lock.lock()
        Self.seen.append(bearer)
        let accepted = bearer == Self.accepted
        let refusal = Self.refusal
        Self.lock.unlock()

        let (status, contentType, body): (Int, String, String) =
            switch (accepted, refusal) {
            case (true, _): (200, "application/json", "[]")
            case (false, .unauthorized): (401, "application/json", #"{"detail":"invalid token"}"#)
            case (false, .proxyForbidden): (403, "text/plain", "Forbidden")
            case (false, .appForbidden): (403, "application/json", #"{"detail":"owner only"}"#)
            case (false, .deviceRevoked): (401, "application/json", #"{"detail":"device_revoked"}"#)
            }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class TokenHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String

    init(_ value: String) { self.value = value }

    var token: String {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); defer { lock.unlock() }; value = newValue }
    }
}

final class FailureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        value += 1
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
