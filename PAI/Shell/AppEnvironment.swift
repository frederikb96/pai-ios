import Foundation
import Observation
import PAIKit
import SwiftUI

/// Where the app's connection and its stores live.
///
/// One place builds the API client, so the request factory's guarantee — that base URL and bearer
/// header are owned in exactly one spot — cannot be lost by a second construction site.
///
/// Credentials are held here rather than read from the Keychain per request: a Keychain lookup on
/// every call is both slow and a second source of truth for what the app is currently signed in
/// as.
@Observable
@MainActor
final class AppEnvironment {

    private(set) var router: Router
    private(set) var connection: Connection?

    /// Set when the backend refused the stored token, so the shell can offer a way back that is
    /// distinct from first launch.
    private(set) var lastAuthFailure: String?

    var backendURL: String {
        didSet { defaults.set(backendURL, forKey: Self.backendURLKey) }
    }

    private let defaults: UserDefaults
    private let tokens: KeychainTokenStore

    /// Everything that only exists once the app has somewhere to talk to.
    ///
    /// Grouped rather than a set of optionals so "configured" is one question with one answer;
    /// separate optionals drift into states where some are set and some are not.
    struct Connection {
        let apiClient: PaiApiClient
        let sessions: SessionListStore
        let machines: MachineStore
        let transcript: TranscriptStore
        let settings: SettingsStore
    }

    private static let backendURLKey = "backendURL"
    static let defaultBackendURL = "https://pai.frederikberg.com"

    init(defaults: UserDefaults = .standard, tokens: KeychainTokenStore = KeychainTokenStore()) {
        self.defaults = defaults
        self.tokens = tokens
        self.backendURL = defaults.string(forKey: Self.backendURLKey) ?? Self.defaultBackendURL
        self.router = Router(gate: .needsConfiguration)

        if tokens.read() != nil {
            connect()
        }
    }

    /// Store a token and bring the connection up. Returns false if the URL is unusable.
    @discardableResult
    func signIn(backendURL url: String, token: String) -> Bool {
        backendURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tokens.write(token) else { return false }
        return connect()
    }

    /// Called when a request comes back 401 or 403.
    ///
    /// The token is cleared as well as the gate moved: leaving a rejected credential in the
    /// Keychain means the next launch tries it again and lands back here, which reads as the app
    /// being broken rather than as needing a new token.
    func handleAuthenticationFailure(detail: String?) {
        tokens.write(nil)
        connection = nil
        lastAuthFailure = detail
        router.rejectToken()
    }

    func signOut() {
        tokens.write(nil)
        connection = nil
        lastAuthFailure = nil
        router = Router(gate: .needsConfiguration)
    }

    @discardableResult
    private func connect() -> Bool {
        guard
            let factory = try? PaiRequestFactory(
                baseURL: backendURL,
                tokenProvider: { [tokens] in tokens.read() }
            )
        else {
            return false
        }

        let client = PaiApiClient(requestFactory: factory)
        connection = Connection(
            apiClient: client,
            sessions: SessionListStore(api: client),
            machines: MachineStore(api: client),
            transcript: TranscriptStore(),
            settings: SettingsStore(apiClient: client, storage: defaults)
        )
        lastAuthFailure = nil
        router.gate = .ready
        return true
    }

    /// The fetches that must happen before any screen asks a question that depends on them.
    ///
    /// Secret presence is the one that bites: a cold start that has not asked yet refuses
    /// recording with no explanation, which reads as a broken feature rather than an
    /// unconfigured one.
    func loadStartupState() async {
        guard let connection else { return }
        await connection.settings.refreshSecretPresence()
        await connection.machines.refresh()
    }
}
