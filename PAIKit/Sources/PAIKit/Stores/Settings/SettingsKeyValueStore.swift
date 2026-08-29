import Foundation

/// Everything client-side settings state persists to — the `UserDefaults` counterpart of the
/// web's `localStorage`.
///
/// `UserDefaults` is a Foundation type, but on Linux it exists only as an unreliable shim
/// (swift-corelibs-foundation backs it with no real persistence store), so nothing here can
/// depend on it directly without losing the free Linux test run. Every store in this directory
/// depends on this protocol instead. **The app target supplies the real implementation** —
/// two one-line methods over a real `UserDefaults` — and tests supply an in-memory fake
/// (`SettingsInMemoryKeyValueStore`, `PAIKit/Tests/PAIKitTests/`).
///
/// Deliberately just two methods, both raw `Data`, rather than one typed accessor per value
/// kind: `UserDefaults.bool(forKey:)` and friends return a non-optional default (`false`, `0`)
/// for a key that was never set, which silently collapses "unset" and "set to the zero value" —
/// exactly the distinction a fresh install needs to get right. Reading and writing everything as
/// JSON through `SettingsCoding` below sidesteps that gotcha once, for every value kind, rather
/// than requiring every call site to re-derive presence from a magic default.
public protocol SettingsKeyValueStore: Sendable {
    func data(forKey key: String) -> Data?
    func setData(_ value: Data?, forKey key: String)
}

/// JSON-codable convenience over `SettingsKeyValueStore`, so a store reads and writes `String`,
/// `Bool`, `Double`, an array or a dictionary through the same two calls rather than plumbing a
/// type-specific method through the protocol for each.
extension SettingsKeyValueStore {
    func value<T: Decodable>(forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    func setValue(_ value: (some Encodable)?, forKey key: String) {
        guard let value else {
            setData(nil, forKey: key)
            return
        }
        setData(try? JSONEncoder().encode(value), forKey: key)
    }
}
