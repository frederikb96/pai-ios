import Foundation
import Observation

/// What `UserSettingsStore` needs from the API; `PaiApiClient` conforms structurally.
public protocol UserSettingsApiClient: Sendable {
    func getMySettings() async throws -> UserSettings
    func updateMySettings(_ patch: UserSettingsPatch) async throws -> UserSettings
}

extension PaiApiClient: UserSettingsApiClient {}

/// The person's own settings, read from the backend and written back on every change. The server's
/// row is the authority; the last answer is kept on the phone only so the first moments of a launch
/// (before the network answers, or with none) already use the person's choices.
///
/// Mirrors the web's `stores/userSettings.ts`: a change shows at once, the server's answer replaces
/// it, and a refused write puts the old values back.
@MainActor
@Observable
public final class UserSettingsStore {
    private static let cacheKey = "userSettings"

    /// `nil` until a cached copy or the first answer exists.
    public private(set) var settings: UserSettings?
    /// The last write that was refused, for the screen to show once.
    public private(set) var errorMessage: String?

    private let api: any UserSettingsApiClient
    private let cache: SettingsKeyValueStore

    public init(api: any UserSettingsApiClient, cache: SettingsKeyValueStore) {
        self.api = api
        self.cache = cache
        settings = cache.value(forKey: Self.cacheKey)
    }

    public func load() async {
        guard let loaded = try? await api.getMySettings() else { return }
        keep(loaded)
    }

    /// Shows the change at once, then keeps the server's answer. Returns whether it was saved.
    @discardableResult
    public func update(_ patch: UserSettingsPatch) async -> Bool {
        let before = settings
        if let before { settings = patch.applied(to: before) }
        errorMessage = nil
        do {
            keep(try await api.updateMySettings(patch))
            return true
        } catch {
            settings = before
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save the setting"
            return false
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    private func keep(_ next: UserSettings) {
        settings = next
        cache.setValue(next, forKey: Self.cacheKey)
    }
}
