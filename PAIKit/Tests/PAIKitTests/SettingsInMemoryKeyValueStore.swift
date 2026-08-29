import Foundation
@testable import PAIKit

/// The fake `SettingsKeyValueStore` every Settings test builds a store on — a plain dictionary,
/// so a fresh instance is exactly what a fresh install's `UserDefaults` looks like: empty.
final class SettingsInMemoryKeyValueStore: SettingsKeyValueStore, @unchecked Sendable {
    private var storage: [String: Data] = [:]

    func data(forKey key: String) -> Data? {
        storage[key]
    }

    func setData(_ value: Data?, forKey key: String) {
        storage[key] = value
    }
}
