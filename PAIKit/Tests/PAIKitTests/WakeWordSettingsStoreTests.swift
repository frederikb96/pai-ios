import XCTest
@testable import PAIKit

/// Neither the class nor any test method here is `@MainActor`, even though `WakeWordSettingsStore`
/// correctly is — a Linux-only XCTest discovery crash fires when a *discovered test method*
/// carries that isolation (see `SettingsSmtpSettingsStoreTests`, the same pattern). Every store
/// access below is `await`ed instead.
final class WakeWordSettingsStoreTests: XCTestCase {
    func testAFreshStoreStartsWithTheFullChart() async {
        let store = await WakeWordSettingsStore(storage: SettingsInMemoryKeyValueStore())
        let config = await store.config
        XCTAssertEqual(config, .fullChart)
    }

    func testSetOfflineCommandsPersistsAcrossANewStoreOverTheSameStorage() async {
        let storage = SettingsInMemoryKeyValueStore()
        let first = await WakeWordSettingsStore(storage: storage)
        await first.setOfflineCommands([.start])

        let second = await WakeWordSettingsStore(storage: storage)
        let config = await second.config
        XCTAssertEqual(config.offlineCommands, [.start])
    }

    func testUseStartOnlyFallbackMatchesTheDocumentedFallback() async {
        let store = await WakeWordSettingsStore(storage: SettingsInMemoryKeyValueStore())
        await store.useStartOnlyFallback()
        let config = await store.config
        XCTAssertEqual(config, .startOnlyFallback)
    }

    func testUseFullChartRestoresEveryCommand() async {
        let store = await WakeWordSettingsStore(storage: SettingsInMemoryKeyValueStore())
        await store.useStartOnlyFallback()
        await store.useFullChart()
        let config = await store.config
        XCTAssertEqual(config, .fullChart)
    }

    /// An empty set degrades to the full chart rather than to "the offline engine listens for
    /// nothing" — silently disabling every command is a worse default than the one Freddy wants.
    func testSettingAnEmptySetFallsBackToTheFullChartRatherThanListeningForNothing() async {
        let store = await WakeWordSettingsStore(storage: SettingsInMemoryKeyValueStore())
        await store.setOfflineCommands([])
        let config = await store.config
        XCTAssertEqual(config, .fullChart)
    }

    func testAnUnrecognizedStoredValueIsIgnoredRatherThanCrashingOrPoisoningTheRest() async {
        let storage = SettingsInMemoryKeyValueStore()
        storage.setValue(["not-a-real-command"], forKey: "wakeWordOfflineCommands")
        let store = await WakeWordSettingsStore(storage: storage)
        let config = await store.config
        XCTAssertEqual(config, .fullChart)
    }
}
