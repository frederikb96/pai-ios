import XCTest

@testable import PAIKit

/// The draft-and-save half of the spoken voice settings: what counts as dirty, what a typed
/// speed has to be before Save is offered, and what an empty field sends.
///
/// Neither the class nor any test method is `@MainActor`, even though the store correctly is —
/// see `SettingsSmtpSettingsStoreTests` for the Linux XCTest discovery crash that forbids it.
/// Every store access is `await`ed instead.
final class SpokenVoiceSettingsStoreTests: XCTestCase {

    override func tearDown() {
        PaiStubURLProtocol.reset()
        super.tearDown()
    }

    @MainActor
    private static func makeStore() throws -> SpokenVoiceSettingsStore {
        let factory = try PaiRequestFactory(
            baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let client = PaiApiClient(
            requestFactory: factory, urlSession: PaiStubURLProtocol.makeSession())
        return SpokenVoiceSettingsStore(apiClient: client)
    }

    private func stubSettings(voice: String = "null", speed: Double = 1.0) {
        PaiStubURLProtocol.stub = .init(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(
                """
                {"computer_voice":\(voice),"computer_delivery":null,"computer_speed":null,
                 "call_voice_id":null,"call_speed":\(speed),
                 "stt_keyterms":[],"stt_language":null,"stt_no_verbatim":false,
                 "debug_recordings_enabled":true,
                 "updated_at":"2026-09-20T12:00:00.123456+00:00"}
                """.utf8)
        )
    }

    private func loaded(
        computerVoice: String? = nil, computerDelivery: String? = nil,
        callVoiceId: String? = nil, callSpeed: Double = 1.0, sttKeyterms: [String] = []
    ) -> SpokenVoiceSettings {
        SpokenVoiceSettings(
            computerVoice: computerVoice, computerDelivery: computerDelivery, computerSpeed: nil,
            callVoiceId: callVoiceId, callSpeed: callSpeed, sttKeyterms: sttKeyterms, sttLanguage: nil,
            sttNoVerbatim: false, debugRecordingsEnabled: true, updatedAt: "2026-09-20T12:00:00Z")
    }

    /// An unset field and an empty text field are the same thing to a person, and have to be the
    /// same thing here — otherwise opening the screen and saving writes four empty strings over
    /// four nulls.
    func testAnUnsetFieldRoundTripsAsEmptyAndBackToNull() {
        let draft = SpokenVoiceSettingsDraft(loaded: loaded())

        XCTAssertEqual(draft.computerVoice, "")
        XCTAssertEqual(draft.computerDelivery, "")
        XCTAssertEqual(draft.callVoiceId, "")

        let update = draft.asUpdate()
        XCTAssertNil(update?.computerVoice)
        XCTAssertNil(update?.computerDelivery)
        XCTAssertNil(update?.callVoiceId)
    }

    /// The speed is a string in the draft so a half-typed number is a state the field can be in.
    /// It must not be a state Save accepts: a value silently becoming 1.0 is exactly the outcome
    /// that reads as the setting not working.
    func testAHalfTypedOrOutOfRangeSpeedCannotBeSaved() {
        for bad in ["", "-", "abc", "0.1", "1.3", "9"] {
            var draft = SpokenVoiceSettingsDraft(loaded: loaded())
            draft.callSpeed = bad
            XCTAssertNil(draft.speed, "expected \(bad.debugDescription) to be unusable")
            XCTAssertNil(draft.asUpdate(), "expected no update for \(bad.debugDescription)")
        }
    }

    func testTheBoundsThemselvesAreUsable() {
        for good in [callSpeedRange.lowerBound, 1.0, callSpeedRange.upperBound] {
            var draft = SpokenVoiceSettingsDraft(loaded: loaded())
            draft.callSpeed = String(good)
            XCTAssertEqual(draft.speed, good)
        }
    }

    /// The stored speed has to come back as something `Double(_:)` reads again — a locale that
    /// wrote a comma separator would round-trip into a save that cannot parse its own field.
    func testAStoredSpeedRoundTripsThroughTheTextField() {
        let draft = SpokenVoiceSettingsDraft(loaded: loaded(callSpeed: 1.15))

        XCTAssertEqual(draft.callSpeed, "1.15")
        XCTAssertEqual(draft.speed, 1.15)
    }

    /// Clearing a field has to reach the backend as `null`: an omitted key means "leave as-is"
    /// there, so a cleared voice that was simply left out of the body would never clear.
    func testAClearedFieldIsSentAsNullNotOmitted() throws {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded(computerVoice: "cedar"))
        draft.computerVoice = ""
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(XCTUnwrap(draft.asUpdate())))
        let object = try XCTUnwrap(body as? [String: Any])
        XCTAssertTrue(object.keys.contains("computer_voice"))
        XCTAssertTrue(object["computer_voice"] is NSNull)
    }

    /// Key terms travel as a list, and one ElevenLabs would refuse blocks Save rather than
    /// failing the whole PUT server-side.
    func testKeyTermsAreSplitAndAnUnacceptableOneBlocksSave() {
        var draft = SpokenVoiceSettingsDraft(loaded: loaded(sttKeyterms: ["Computer", "Kai"]))
        XCTAssertEqual(draft.sttKeyterms, "Computer, Kai")
        draft.sttKeyterms = " Computer ,Kai,, PAI "
        XCTAssertEqual(draft.asUpdate()?.sttKeyterms, ["Computer", "Kai", "PAI"])

        draft.sttKeyterms = "Computer, Supercalifragilistic word"
        XCTAssertNotNil(draft.keytermProblem)
        XCTAssertNil(draft.asUpdate())
    }

    func testBeforeLoadNothingIsDirtyOrSaveable() async throws {
        let store = try await Self.makeStore()

        let isDirty = await store.isDirty
        let canSave = await store.canSave
        XCTAssertFalse(isDirty)
        XCTAssertFalse(canSave)
    }

    func testLoadingLeavesTheDraftCleanAndSaveUnoffered() async throws {
        stubSettings()
        let store = try await Self.makeStore()

        await store.load()

        let loadedValue = await store.loaded
        let isDirty = await store.isDirty
        let canSave = await store.canSave
        XCTAssertNotNil(loadedValue)
        XCTAssertFalse(isDirty)
        XCTAssertFalse(canSave)
    }

    func testEditingAFieldOffersSaveAndAnUnusableSpeedWithdrawsIt() async throws {
        stubSettings()
        let store = try await Self.makeStore()
        await store.load()

        await MainActor.run { store.draft?.computerVoice = "marin" }
        var isDirty = await store.isDirty
        var canSave = await store.canSave
        XCTAssertTrue(isDirty)
        XCTAssertTrue(canSave)

        await MainActor.run { store.draft?.callSpeed = "not a number" }
        isDirty = await store.isDirty
        canSave = await store.canSave
        XCTAssertTrue(isDirty)
        XCTAssertFalse(canSave, "a dirty draft with an unusable speed must not be savable")
    }
}
