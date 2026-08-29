import XCTest

@testable import PAIKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A refused credential has to be noticed somewhere that cannot be skipped.
///
/// Every call on the app's first-load path discards its error, because most of those failures are
/// genuinely not worth a banner — and that is exactly why an expired token used to read as an app
/// with nothing in it. Noticing inside the client means a caller that swallows its error still
/// cannot swallow this one.
final class PaiApiClientAuthFailureTests: XCTestCase {

    private func makeClient(
        status: Int, body: String, onFailure: @escaping @Sendable (PaiError) -> Void
    ) -> PaiApiClient {
        PaiStubURLProtocol.reset()
        PaiStubURLProtocol.stub = PaiStubURLProtocol.Stub(
            statusCode: status, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
        let factory = try! PaiRequestFactory(baseURL: "https://example.invalid", tokenProvider: { "stale" })
        return PaiApiClient(
            requestFactory: factory,
            urlSession: PaiStubURLProtocol.makeSession(),
            onAuthenticationFailure: onFailure
        )
    }

    func testA401NotifiesEvenThoughTheCallerDiscardsTheError() async {
        let box = FailureBox()
        let client = makeClient(status: 401, body: #"{"detail":"token expired"}"#) { box.record($0) }

        // `try?` is what every first-load caller does. The notification must survive it.
        _ = try? await client.getSessions()

        XCTAssertEqual(box.count, 1)
        XCTAssertEqual(box.last?.userMessage, "token expired")
    }

    func testA403AlsoNotifies() async {
        let box = FailureBox()
        let client = makeClient(status: 403, body: #"{"detail":"not an owner"}"#) { box.record($0) }
        _ = try? await client.getSessions()
        XCTAssertEqual(box.count, 1)
    }

    func testAnOrdinaryServerErrorDoesNotSignOutTheUser() async {
        let box = FailureBox()
        let client = makeClient(status: 500, body: #"{"detail":"boom"}"#) { box.record($0) }

        _ = try? await client.getSessions()

        // Treating any failure as an auth failure would throw the token away every time the
        // backend hiccups, which is worse than the bug this callback fixes.
        XCTAssertEqual(box.count, 0)
    }

    func testASuccessfulResponseNeverNotifies() async {
        let box = FailureBox()
        let client = makeClient(status: 200, body: "[]") { box.record($0) }
        _ = try? await client.getSessions()
        XCTAssertEqual(box.count, 0)
    }
}

private final class FailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [PaiError] = []

    func record(_ error: PaiError) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(error)
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return errors.count
    }

    var last: PaiError? {
        lock.lock()
        defer { lock.unlock() }
        return errors.last
    }
}
