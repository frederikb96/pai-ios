import XCTest

@testable import PAIKit

@MainActor
final class SettingsThemeTests: XCTestCase {

    func testAFreshInstallFollowsTheSystem() async {
        let storage = InMemorySettingsStorage()
        let store = SettingsStore(apiClient: makeClient(), storage: storage)

        // Not merely "some default" — following the system is the only choice that is right
        // before the user has expressed one, and the web defaults the same way.
        XCTAssertEqual(store.theme, .system)
    }

    func testAChosenThemeSurvivesARelaunch() async {
        let storage = InMemorySettingsStorage()
        let first = SettingsStore(apiClient: makeClient(), storage: storage)
        first.setTheme(.dark)

        // A second store over the same storage is what a relaunch looks like from here.
        let second = SettingsStore(apiClient: makeClient(), storage: storage)
        XCTAssertEqual(second.theme, .dark)
    }

    func testEveryThemeRoundTripsThroughStorage() async {
        for theme in AppTheme.allCases {
            let storage = InMemorySettingsStorage()
            SettingsStore(apiClient: makeClient(), storage: storage).setTheme(theme)
            XCTAssertEqual(SettingsStore(apiClient: makeClient(), storage: storage).theme, theme)
        }
    }

    private func makeClient() -> PaiApiClient {
        let factory = try! PaiRequestFactory(baseURL: "https://example.invalid", tokenProvider: { nil })
        return PaiApiClient(requestFactory: factory)
    }
}

/// A dictionary standing in for `UserDefaults`, which does not exist on Linux.
final class InMemorySettingsStorage: SettingsKeyValueStore, @unchecked Sendable {
    private var values: [String: Data] = [:]

    func data(forKey key: String) -> Data? { values[key] }

    func setData(_ value: Data?, forKey key: String) {
        if let value {
            values[key] = value
        } else {
            values.removeValue(forKey: key)
        }
    }
}
