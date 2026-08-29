import XCTest
@testable import PAIKit

/// `SmtpSettingsStore`'s dirty-tracking and validation are the real logic here — the network
/// calls themselves are already covered by `PaiApiClientTests`. These exercise the
/// load → edit → dirty → save state machine and the two boundaries the backend also validates
/// (port range, recipient shape), since a refactor could silently stop enforcing either without
/// any network test noticing.
///
/// Neither the class nor any test method here is `@MainActor`, even though `SmtpSettingsStore`
/// correctly is — a Linux-only XCTest discovery crash (`_arrayForceCast` on a
/// `@MainActor`-isolated method reference) fires when a *discovered test method* carries that
/// isolation. Every store access below is `await`ed instead, which crosses into the actor
/// without requiring the method itself to be isolated.
final class SettingsSmtpSettingsStoreTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    /// `static`, not an instance method: an instance method here would need to "send" the test
    /// case's own `self` across to `@MainActor`, which a non-`Sendable` `XCTestCase` cannot do.
    @MainActor
    private static func makeStore() throws -> SmtpSettingsStore {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let client = PaiApiClient(requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        return SmtpSettingsStore(apiClient: client)
    }

    private func stubSmtpSettings(recipient: String = "fberg@posteo.de", port: Int = 465) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                """
                {"host":null,"port":\(port),"security":"ssl","username":null,
                 "from_address":null,"recipient":"\(recipient)","enabled":false,
                 "updated_at":"2026-01-01T00:00:00Z"}
                """.utf8)
        )
    }

    func testBeforeLoadNothingIsSaveableOrTestable() async throws {
        let store = try await Self.makeStore()
        let loaded = await store.loaded
        let draft = await store.draft
        let canSave = await store.canSave
        let canSendTest = await store.canSendTest
        XCTAssertNil(loaded)
        XCTAssertNil(draft)
        XCTAssertFalse(canSave)
        XCTAssertFalse(canSendTest)
    }

    func testLoadPopulatesACleanDraftThatIsNotDirty() async throws {
        stubSmtpSettings()
        let store = try await Self.makeStore()
        await store.load()

        let loaded = await store.loaded
        let isDirty = await store.isDirty
        let canSave = await store.canSave
        let canSendTest = await store.canSendTest
        XCTAssertNotNil(loaded)
        XCTAssertFalse(isDirty)
        XCTAssertFalse(canSave, "clean draft has nothing to save")
        XCTAssertTrue(canSendTest, "clean and loaded is exactly when a test send is allowed")
    }

    func testEditingTheDraftMarksItDirtyAndBlocksTestSend() async throws {
        stubSmtpSettings()
        let store = try await Self.makeStore()
        await store.load()

        await MainActor.run { store.draft?.host = "mail.example.com" }

        let isDirty = await store.isDirty
        let canSendTest = await store.canSendTest
        XCTAssertTrue(isDirty)
        XCTAssertFalse(canSendTest, "the web disables test-send while dirty: it uses what is stored, not the draft")
    }

    func testPortOutsideOneTo65535IsInvalid() async throws {
        stubSmtpSettings()
        let store = try await Self.makeStore()
        await store.load()

        await MainActor.run { store.draft?.port = 0 }
        var isPortValid = await store.isPortValid
        let canSave = await store.canSave
        XCTAssertFalse(isPortValid)
        XCTAssertFalse(canSave)

        await MainActor.run { store.draft?.port = 65_536 }
        isPortValid = await store.isPortValid
        XCTAssertFalse(isPortValid)

        await MainActor.run { store.draft?.port = 65_535 }
        isPortValid = await store.isPortValid
        XCTAssertTrue(isPortValid)
    }

    func testRecipientWithoutAtSignIsInvalid() async throws {
        stubSmtpSettings()
        let store = try await Self.makeStore()
        await store.load()

        await MainActor.run { store.draft?.recipient = "not-an-email" }
        let isRecipientValid = await store.isRecipientValid
        let canSave = await store.canSave
        XCTAssertFalse(isRecipientValid)
        XCTAssertFalse(canSave, "an invalid recipient blocks Save even though the draft is dirty")
    }

    func testSaveSendsTheWholeDraftNotASelectivePatch() async throws {
        stubSmtpSettings()
        let store = try await Self.makeStore()
        await store.load()
        await MainActor.run {
            store.draft?.host = "mail.example.com"
            store.draft?.enabled = true
        }

        stubSmtpSettings(recipient: "fberg@posteo.de")
        await store.save()

        let body = PaiStubURLProtocol.capturedBody.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let object = try XCTUnwrap(body as? [String: Any])
        // Every writable field must be present — SmtpSettingsUpdate's synthesized Encodable
        // cannot express "leave alone" vs "clear to null" for an omitted key, so this store
        // follows the web's whole-draft Save rather than a patch that could silently drop one.
        for field in ["host", "port", "security", "recipient", "enabled"] {
            XCTAssertTrue(object.keys.contains(field), "\(field) missing from the PUT body")
        }
    }

    func testSaveClearsDirtyOnSuccess() async throws {
        stubSmtpSettings()
        let store = try await Self.makeStore()
        await store.load()
        await MainActor.run { store.draft?.enabled = true }

        stubSmtpSettings()
        await store.save()

        let isDirty = await store.isDirty
        let canSendTest = await store.canSendTest
        XCTAssertFalse(isDirty)
        XCTAssertTrue(canSendTest)
    }
}
