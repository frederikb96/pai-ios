import Foundation
import Observation

/// Owns whether this install can receive a push notification, and decides when the backend needs
/// telling about its token.
///
/// The Apple-only half — asking `UNUserNotificationCenter` for permission and receiving the token
/// from the app delegate — stays in the app target and calls into this. Everything that can be
/// got *wrong* is here: which states are worth re-asking from, when a token is stale, and not
/// posting the same token on every launch. That half is proven on the free Linux runner.
@MainActor
@Observable
public final class PushRegistrationStore {

    private enum Keys {
        static let registration = "pushRegistration"
    }

    private let storage: SettingsKeyValueStore
    /// Injected rather than taking `PaiApiClient` directly, so this type stays free of the
    /// networking layer and a test can assert what was sent without a stub URL protocol.
    ///
    /// Returns the token the backend actually stored, which is its own normalised form rather
    /// than necessarily the string sent. Remembering what came back, instead of what went out,
    /// is what stops a normalisation this client does not perform from looking like a token that
    /// was never registered — which would re-post on every launch, forever, with nothing wrong.
    private let registerToken: @Sendable (String) async throws -> String

    public private(set) var registration: PushRegistration

    public init(
        storage: SettingsKeyValueStore,
        registerToken: @escaping @Sendable (String) async throws -> String
    ) {
        self.storage = storage
        self.registerToken = registerToken
        registration = storage.value(forKey: Keys.registration) ?? PushRegistration()
    }

    /// Whether it is worth showing the system prompt. The prompt appears once per install and
    /// never again, so this is the difference between asking at a moment that makes sense and
    /// burning the one chance on a cold first launch.
    public var shouldRequestAuthorization: Bool {
        registration.canRequestAuthorization
    }

    public func recordAuthorization(granted: Bool) {
        registration.status = granted ? .authorized : .denied
        if !granted { registration.deviceToken = nil }
        persist()
    }

    /// Apple issued a token. Stored immediately and separately from what the backend has
    /// acknowledged, so a device that is offline right now still knows to register later.
    public func recordDeviceToken(_ token: String) {
        registration.status = .authorized
        registration.deviceToken = token
        registration.lastError = nil
        persist()
    }

    public func recordRegistrationFailure(_ message: String) {
        registration.status = .failed
        registration.lastError = message
        persist()
    }

    /// Tells the backend about the current token, if it has not already been told about this one.
    ///
    /// Safe to call on every launch and after every foreground: the no-op case is the common one.
    /// A failure is recorded and left for the next call rather than retried in a loop — the next
    /// launch is soon enough for a device token, and a retry loop against a backend that is down
    /// is worse than waiting.
    public func registerWithBackendIfNeeded() async {
        guard registration.needsBackendRegistration, let token = registration.deviceToken else { return }
        do {
            registration.registeredToken = try await registerToken(token)
            registration.lastError = nil
        } catch {
            registration.lastError = String(describing: error)
        }
        persist()
    }

    private func persist() {
        storage.setValue(registration, forKey: Keys.registration)
    }
}
