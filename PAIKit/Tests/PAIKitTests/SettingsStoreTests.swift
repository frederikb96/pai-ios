import XCTest
@testable import PAIKit

/// `SettingsStore`'s defaults are the fresh-install contract: `stores/settings.ts` is explicit
/// that every one of these has to read as "quiet" the first time the app ever runs.
/// `testDefaultsOnAFreshInstall` was run against a build with `silenceDetectionEnabled`
/// hardcoded `true` and failed as expected, which is what makes a green run of it trustworthy
/// rather than a default that happens to match by coincidence.
///
/// Every test body runs inside `MainActor.run` rather than the class or its methods being
/// `@MainActor` — `SettingsStore` and friends are correctly `@MainActor`, but a Linux XCTest
/// binary crashes at test-discovery time (`_arrayForceCast` on a `@MainActor`-isolated method
/// reference, `swift_dynamicCastFailure`) when the *test method itself* carries that isolation.
/// Hopping inside the body sidesteps the discovery bug without touching the production code's
/// isolation.
final class SettingsStoreTests: XCTestCase {

    @MainActor
    private static func makeClient() throws -> PaiApiClient {
        let factory = try PaiRequestFactory(baseURL: "https://pai.example.com", tokenProvider: { nil })
        return PaiApiClient(requestFactory: factory)
    }

    /// `static`, not an instance method: an instance method here would need to "send" the test
    /// case's own `self` across to `@MainActor`, which a non-`Sendable` `XCTestCase` cannot do.
    /// Called as `Self.makeStore` at every use site — inside a nested closure, unqualified
    /// lookup does not find a static member of the enclosing type.
    @MainActor
    private static func makeStore(
        storage: SettingsKeyValueStore = SettingsInMemoryKeyValueStore()
    ) throws -> SettingsStore {
        SettingsStore(apiClient: try makeClient(), storage: storage)
    }

    func testDefaultsOnAFreshInstall() async throws {
        try await MainActor.run {
            let store = try Self.makeStore()

            XCTAssertEqual(store.sttLanguage, .auto)
            XCTAssertEqual(store.micDeviceId, "")
            XCTAssertEqual(store.silenceDetectionEnabled, false)
            XCTAssertEqual(store.silenceThreshold, 0.005)
            XCTAssertEqual(store.silenceDurationMs, 3000)
            XCTAssertEqual(store.sentMessages, [])
            XCTAssertEqual(store.recordings, [])
            XCTAssertEqual(store.expandPreferences, [:])
            XCTAssertEqual(store.showsNoteLineNumbers, false)
            XCTAssertEqual(store.noteToolbarLayout, NoteToolbarLayout.defaultLayout)

            // The toggles the web's own regression test singles out as the ones that used to
            // default to true (`settings.test.ts`) — every one of them must read false here too.
            for key in ["read_call", "edit_call", "bash_call", "skill_call", "system_agent_message"] {
                XCTAssertFalse(store.isExpandEnabled(key), key)
            }
        }
    }

    func testSetSttLanguagePersistsAcrossStoreInstances() async throws {
        try await MainActor.run {
            let storage = SettingsInMemoryKeyValueStore()
            let first = try Self.makeStore(storage: storage)
            first.setSttLanguage(.de)

            let second = try Self.makeStore(storage: storage)
            XCTAssertEqual(second.sttLanguage, .de)
        }
    }

    func testSetShowsNoteLineNumbersPersistsAcrossStoreInstances() async throws {
        try await MainActor.run {
            let storage = SettingsInMemoryKeyValueStore()
            let first = try Self.makeStore(storage: storage)
            first.setShowsNoteLineNumbers(true)

            let second = try Self.makeStore(storage: storage)
            XCTAssertEqual(second.showsNoteLineNumbers, true)
        }
    }

    func testSetNoteToolbarLayoutPersistsAcrossStoreInstances() async throws {
        try await MainActor.run {
            let storage = SettingsInMemoryKeyValueStore()
            let first = try Self.makeStore(storage: storage)
            first.setNoteToolbarLayout([.link, .undo, .bold])

            let second = try Self.makeStore(storage: storage)
            XCTAssertEqual(second.noteToolbarLayout, [.link, .undo, .bold])
        }
    }

    /// Simulates what a real fresh install never produces but a genuinely old or new app version
    /// on the same device could: a stored layout naming an action this build has never heard of,
    /// alongside ones it recognises. The key is `SettingsStore`'s own private storage key,
    /// duplicated here as a literal because there is no other way to write behind the public API
    /// — see `NoteToolbarLayoutTests` for the same guarantee tested directly against
    /// `NoteToolbarLayout.sanitize(rawIds:)`, with no dependency on this string staying in sync.
    func testAnUnrecognisedStoredActionIsDroppedRatherThanDiscardingTheWholeLayout() async throws {
        try await MainActor.run {
            let storage = SettingsInMemoryKeyValueStore()
            storage.setData(
                try? JSONEncoder().encode(["bold", "future-action", "quote"]), forKey: "noteToolbarLayout")

            let store = try Self.makeStore(storage: storage)
            XCTAssertEqual(store.noteToolbarLayout, [.bold, .quote])
        }
    }

    func testExpandPreferenceRoundTripsAndLeavesOtherKeysAtTheirDefault() async throws {
        try await MainActor.run {
            let storage = SettingsInMemoryKeyValueStore()
            let first = try Self.makeStore(storage: storage)
            first.setExpandPreference("bash_call", enabled: true)

            let second = try Self.makeStore(storage: storage)
            XCTAssertTrue(second.isExpandEnabled("bash_call"))
            XCTAssertFalse(second.isExpandEnabled("edit_call"))
        }
    }

    func testSentMessagesCapAtTenNewestFirst() async throws {
        try await MainActor.run {
            let store = try Self.makeStore()
            for i in 0..<12 {
                store.saveSentMessage("message \(i)")
            }
            XCTAssertEqual(store.sentMessages.count, 10)
            XCTAssertEqual(store.sentMessages.first?.text, "message 11")
            XCTAssertEqual(store.sentMessages.last?.text, "message 2")
        }
    }

    func testSavingSentMessageWithOnlyWhitespaceIsIgnored() async throws {
        try await MainActor.run {
            let store = try Self.makeStore()
            store.saveSentMessage("   \n  ")
            XCTAssertEqual(store.sentMessages, [])
        }
    }

    /// The 11th recording evicts the 10th-oldest, and that specific entry — not just "some
    /// entry" — is what the caller needs to know so it can delete the matching audio file.
    func testRecordingsCapAtTenAndReportsExactlyTheEvictedEntry() async throws {
        try await MainActor.run {
            let store = try Self.makeStore()
            var evicted: [RecordingMeta] = []
            store.onRecordingEvicted = { evicted.append($0) }

            for i in 0..<11 {
                store.saveRecording(RecordingMeta(timestampMs: Double(i), durationMs: 1000))
            }

            XCTAssertEqual(store.recordings.count, 10)
            XCTAssertEqual(evicted.count, 1)
            XCTAssertEqual(evicted.first?.timestampMs, 0)
            XCTAssertEqual(store.recordings.map(\.timestampMs), [10, 9, 8, 7, 6, 5, 4, 3, 2, 1])
        }
    }

    func testElevenLabsKeyStatusStartsUnknownNotFalse() async throws {
        try await MainActor.run {
            let store = try Self.makeStore()
            // `nil`, not a boolean — a voice gate must be able to tell "not yet asked" from
            // "confirmed unset", which is exactly what this distinction makes possible.
            XCTAssertNil(store.elevenLabsKey.status)
        }
    }
}
