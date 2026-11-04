import XCTest

@testable import PAIKit

@MainActor
final class UserSettingsStoreTests: XCTestCase {
    func testThePatchSendsOnlyWhatWasChangedAndSpellsOutAClearedVoice() throws {
        func sent(_ patch: UserSettingsPatch) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(patch)) as? [String: Any] ?? [:]
        }
        let email = try sent(UserSettingsPatch(emailNotifications: false))
        XCTAssertEqual(Set(email.keys), ["email_notifications"])
        XCTAssertEqual(email["email_notifications"] as? Bool, false)

        XCTAssertEqual(try sent(UserSettingsPatch(recordingMode: .batch))["recording_mode"] as? String, "batch")
        XCTAssertEqual(try sent(UserSettingsPatch(playbackVoice: .set("v1")))["playback_voice_id"] as? String, "v1")
        let cleared = try sent(UserSettingsPatch(playbackVoice: .clear))
        XCTAssertTrue(cleared["playback_voice_id"] is NSNull, "a cleared voice is null, not absent")
        XCTAssertTrue(try sent(UserSettingsPatch()).isEmpty)
    }

    func testTheRowDecodesTheContractShape() throws {
        let json =
            #"{"recording_mode":"batch","playback_voice_id":null,"playback_speed":1.25,"email_notifications":false}"#
        let settings = try JSONDecoder().decode(UserSettings.self, from: Data(json.utf8))
        XCTAssertEqual(
            settings,
            UserSettings(recordingMode: .batch, playbackVoiceId: nil, playbackSpeed: 1.25, emailNotifications: false))
    }

    func testAChangeShowsAtOnceAndTheServersAnswerReplacesIt() async {
        let api = FakeUserSettingsApi(row: UserSettings())
        let store = UserSettingsStore(api: api, cache: SettingsInMemoryKeyValueStore())
        await store.load()
        XCTAssertEqual(store.settings?.recordingMode, .live)

        let saved = await store.update(UserSettingsPatch(recordingMode: .batch))
        XCTAssertTrue(saved)
        XCTAssertEqual(store.settings?.recordingMode, .batch)
        let patches = await api.patches
        XCTAssertEqual(patches.count, 1)
    }

    func testARefusedWritePutsTheOldValuesBack() async {
        let api = FakeUserSettingsApi(row: UserSettings(emailNotifications: true))
        let store = UserSettingsStore(api: api, cache: SettingsInMemoryKeyValueStore())
        await store.load()
        await api.failWrites(with: PaiError.detail("nope", statusCode: 422))

        let saved = await store.update(UserSettingsPatch(emailNotifications: false))
        XCTAssertFalse(saved)
        XCTAssertEqual(store.settings?.emailNotifications, true)
        XCTAssertEqual(store.errorMessage, "nope")
    }

    func testTheLastAnswerIsKeptForTheNextLaunch() async {
        let cache = SettingsInMemoryKeyValueStore()
        let first = UserSettingsStore(api: FakeUserSettingsApi(row: UserSettings(recordingMode: .batch)), cache: cache)
        await first.load()
        let next = UserSettingsStore(api: FakeUserSettingsApi(row: UserSettings()), cache: cache)
        XCTAssertEqual(next.settings?.recordingMode, .batch, "before the network answers")
    }

    func testTheRecordingModeThePressStartsComesFromTheSettings() async throws {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { "jwt" })
        let store = SettingsStore(
            apiClient: PaiApiClient(requestFactory: factory), storage: SettingsInMemoryKeyValueStore())
        XCTAssertEqual(store.defaultRecordingMode, .live, "until the person's settings have been read")
        XCTAssertEqual(store.alternateRecordingMode, .batch)
    }
}

private actor FakeUserSettingsApi: UserSettingsApiClient {
    private var row: UserSettings
    private(set) var patches: [UserSettingsPatch] = []
    private var writeError: Error?

    init(row: UserSettings) { self.row = row }

    func failWrites(with error: Error) { writeError = error }

    func getMySettings() async throws -> UserSettings { row }

    func updateMySettings(_ patch: UserSettingsPatch) async throws -> UserSettings {
        if let writeError { throw writeError }
        patches.append(patch)
        row = patch.applied(to: row)
        return row
    }
}
