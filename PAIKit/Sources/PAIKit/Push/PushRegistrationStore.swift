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
    /// Answers with what the backend actually stored, which for the token is its own normalised
    /// form rather than necessarily the string sent. Remembering what came back, instead of what
    /// went out, is what stops a normalisation this client does not perform from looking like a
    /// token that was never registered — which would re-post on every launch, forever, with
    /// nothing wrong.
    private let registerToken: @Sendable (String, [PushChannel]) async throws -> DeviceRegistration

    public private(set) var registration: PushRegistration

    public init(
        storage: SettingsKeyValueStore,
        registerToken: @escaping @Sendable (String, [PushChannel]) async throws -> DeviceRegistration
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
        let sent = registration.mutedChannels
        do {
            let result = try await registerToken(token, sent.sorted { $0.rawValue < $1.rawValue })
            registration.registeredToken = result.token
            // What the backend reports it holds, and what was sent when it reports nothing. A
            // backend that does not answer about channels has still stored what it was given, so
            // treating silence as "nothing is muted" is the one reading that is certainly wrong.
            registration.registeredMutedChannels =
                result.mutedChannels.map { Set($0.compactMap(PushChannel.init(rawValue:))) } ?? sent
            registration.lastError = nil
        } catch {
            registration.lastError = String(describing: error)
        }
        persist()
    }

    /// Switch one channel on or off for this device, and tell the backend.
    ///
    /// The local choice is recorded and persisted whether or not the call succeeds — the toggle
    /// has to stay where it was put, and `needsBackendRegistration` is what carries an unsent
    /// change to the next launch.
    public func setMuted(_ muted: Bool, for channel: PushChannel) async {
        guard registration.isMuted(channel) != muted else { return }
        if muted {
            registration.mutedChannels.insert(channel)
        } else {
            registration.mutedChannels.remove(channel)
        }
        persist()
        await registerWithBackendIfNeeded()
    }

    private func persist() {
        storage.setValue(registration, forKey: Keys.registration)
    }
}
