import Foundation
import XCTest

@testable import PAIKit

/// Renewal is where a sign-in that should last for months gets lost: a second refresh with a
/// rotated-away refresh token is refused, and a refusal signs out.
final class CredentialRenewerTests: XCTestCase {

    /// Several requests refused at once ask for one refresh, and all of them go again.
    func testConcurrentRefusalsShareOneRefresh() async {
        let store = MemoryTokenSetStore(OidcTokenSet(accessToken: "old", refreshToken: "r1"))
        let provider = RotatingProvider()
        let renewer = CredentialRenewer(
            store: store, refresh: { tokens throws(OidcError) in try await provider.refresh(tokens) }, onRenewed: {})

        let outcomes = await withTaskGroup(of: CredentialRenewal.self) { group in
            for _ in 0..<5 { group.addTask { await renewer.renew(rejecting: "old") } }
            return await group.reduce(into: []) { $0.append($1) }
        }

        XCTAssertEqual(outcomes, [CredentialRenewal](repeating: .renewed, count: 5))
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(store.current, OidcTokenSet(accessToken: "access-1", refreshToken: "refresh-1"))
    }

    /// A request that was in flight while another one's renewal finished comes back refused with
    /// the old token; refreshing again would spend the new refresh token for nothing.
    func testARefusalOfAnAlreadyReplacedTokenIsAnsweredWithoutARefresh() async {
        let store = MemoryTokenSetStore(OidcTokenSet(accessToken: "new", refreshToken: "r2"))
        let provider = RotatingProvider()
        let renewer = CredentialRenewer(
            store: store, refresh: { tokens throws(OidcError) in try await provider.refresh(tokens) }, onRenewed: {})

        let outcome = await renewer.renew(rejecting: "old")

        XCTAssertEqual(outcome, .renewed)
        let calls = await provider.calls
        XCTAssertEqual(calls, 0)
    }

    /// A pasted token has no refresh token and nothing to renew it with.
    func testAPastedTokenCannotBeRenewed() async {
        let renewer = CredentialRenewer(
            store: MemoryTokenSetStore(nil), refresh: { _ throws(OidcError) in throw .unavailable("unused") },
            onRenewed: {})
        let outcome = await renewer.renew(rejecting: "pasted")
        XCTAssertEqual(outcome, .rejected)
    }

    func testAProviderRefusalSignsOut() async {
        let store = MemoryTokenSetStore(OidcTokenSet(accessToken: "old", refreshToken: "r1"))
        let renewer = CredentialRenewer(
            store: store, refresh: { _ throws(OidcError) in throw .rejected("expired") }, onRenewed: {})
        let outcome = await renewer.renew(rejecting: "old")
        XCTAssertEqual(outcome, .rejected)
    }

    /// An unreachable provider keeps the credential, so the next refusal can try again.
    func testAnUnreachableProviderKeepsTheCredential() async {
        let original = OidcTokenSet(accessToken: "old", refreshToken: "r1")
        let store = MemoryTokenSetStore(original)
        let renewer = CredentialRenewer(
            store: store, refresh: { _ throws(OidcError) in throw .unavailable("offline") }, onRenewed: {})

        let outcome = await renewer.renew(rejecting: "old")

        guard case .unavailable = outcome else { return XCTFail("got \(outcome)") }
        XCTAssertEqual(store.current, original)
    }

    /// The share extension's copy is updated before a waiting request goes out again.
    func testOnRenewedRunsAfterTheNewTokensAreStored() async {
        let store = MemoryTokenSetStore(OidcTokenSet(accessToken: "old", refreshToken: "r1"))
        let provider = RotatingProvider()
        let seen = MemoryTokenSetStore(nil)
        let renewer = CredentialRenewer(
            store: store, refresh: { tokens throws(OidcError) in try await provider.refresh(tokens) },
            onRenewed: { if let current = store.current { seen.writeTokenSet(current) } })

        _ = await renewer.renew(rejecting: "old")

        XCTAssertEqual(seen.current?.accessToken, "access-1")
    }
}

final class MemoryTokenSetStore: OidcTokenSetStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: OidcTokenSet?

    init(_ tokens: OidcTokenSet?) { self.tokens = tokens }

    var current: OidcTokenSet? {
        lock.lock()
        defer { lock.unlock() }
        return tokens
    }

    func readTokenSet() -> OidcTokenSet? { current }

    @discardableResult
    func writeTokenSet(_ tokens: OidcTokenSet) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        self.tokens = tokens
        return true
    }
}

/// A provider that rotates the refresh token and, like Zitadel, refuses one it has rotated away.
/// It answers slowly enough that callers arriving together are all waiting while it works.
actor RotatingProvider {
    private(set) var calls = 0
    private var valid: String? = nil

    func refresh(_ tokens: OidcTokenSet) async throws(OidcError) -> OidcTokenSet {
        calls += 1
        if let valid, tokens.refreshToken != valid { throw .rejected("rotated away") }
        try? await Task.sleep(for: .milliseconds(200))
        valid = "refresh-\(calls)"
        return OidcTokenSet(accessToken: "access-\(calls)", refreshToken: valid)
    }
}
