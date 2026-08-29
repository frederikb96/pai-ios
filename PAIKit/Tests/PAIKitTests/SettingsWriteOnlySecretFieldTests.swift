import XCTest
@testable import PAIKit

/// The one property this type exists to guarantee: it can report whether a secret is set, and
/// it has no code path that can hand the value back out. `save`/`clear` only ever assign
/// `status`, never a value field — there is no value field to assign.
///
/// See `SettingsSmtpSettingsStoreTests`'s doc comment for why neither the class nor its test
/// methods are `@MainActor` — a Linux-only XCTest discovery crash, not a requirement of the
/// code under test.
final class SettingsWriteOnlySecretFieldTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    /// `static`, not an instance method: an instance method here would need to "send" the test
    /// case's own `self` across to `@MainActor`, which a non-`Sendable` `XCTestCase` cannot do.
    @MainActor
    private static func makeField(name: SecretName = .elevenlabs) throws -> WriteOnlySecretField {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        return WriteOnlySecretField(name: name, apiClient: client)
    }

    func testStatusStartsUnknown() async throws {
        let field = try await Self.makeField()
        let status = await field.status
        XCTAssertNil(status)
    }

    func testApplyStatusFromABatchedPresenceFetch() async throws {
        let field = try await Self.makeField()
        await MainActor.run { field.applyStatus(SecretStatus(set: true, updatedAt: "2026-01-01T00:00:00Z")) }
        let status = await field.status
        XCTAssertEqual(status?.set, true)
    }

    func testSaveSetsStatusFromTheServerResponse() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"set":true,"updated_at":"2026-01-01T00:00:00Z"}"#.utf8)
        )
        let field = try await Self.makeField()
        await field.save(value: "sk-real-value-never-stored-here")

        let status = await field.status
        let errorMessage = await field.errorMessage
        XCTAssertEqual(status?.set, true)
        XCTAssertNil(errorMessage)
    }

    func testClearSetsStatusToUnset() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"name":"elevenlabs","removed":true}"#.utf8)
        )
        let field = try await Self.makeField()
        await MainActor.run { field.applyStatus(SecretStatus(set: true, updatedAt: "2026-01-01T00:00:00Z")) }

        await field.clear()

        let status = await field.status
        XCTAssertEqual(status?.set, false)
    }

    func testAFailedSaveSurfacesAnErrorAndLeavesStatusUntouched() async throws {
        PaiStubURLProtocol.stub = .init(
            statusCode: 500,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"detail":"internal error"}"#.utf8)
        )
        let field = try await Self.makeField()
        await MainActor.run { field.applyStatus(SecretStatus(set: false, updatedAt: nil)) }

        await field.save(value: "sk-value")

        let errorMessage = await field.errorMessage
        let status = await field.status
        XCTAssertNotNil(errorMessage)
        XCTAssertEqual(status?.set, false, "a failed save must not claim the secret is now set")
    }
}
