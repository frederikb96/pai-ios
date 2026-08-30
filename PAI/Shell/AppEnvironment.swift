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
        /// Exposed as well as the client because the two streaming clients take the factory
        /// directly rather than going through `PaiApiClient`. A screen that needs a stream must be
        /// handed this one — building a second factory would put a second copy of the base URL and
        /// the bearer header in the app, which is the thing having one factory prevents.
        let requestFactory: PaiRequestFactory
        let apiClient: PaiApiClient
        let sessions: SessionListStore
        let machines: MachineStore
        let transcript: TranscriptStore
        let settings: SettingsStore
        /// App-wide rather than per-composer: a draft is how a half-written message reaches
        /// another device, and the web syncs them on the same tick as sessions. Scoped to a screen
        /// it would only sync while that screen happened to be open.
        let drafts: DraftStore
        /// Who is signed in — fetched once, not per screen, since every session-action route is
        /// owner-only and asking again on every menu open would cost a round trip for an answer
        /// that never changes within one sign-in.
        let me: MeStore
        /// App-wide home for a toast/snackbar — see `ToastCenter`'s doc comment for why one is
        /// needed at all.
        let toasts: ToastCenter
        /// Whether this install can receive a push, and whether the backend has been told which
        /// device to send it to. Lives on the connection because a device token is worthless
        /// without a backend to register it against.
        let push: PushRegistrationStore
        /// The microphone, and whatever take is running on it. App-wide because a recording has
        /// to outlive the screen that started it — see `VoiceRecorderController`'s doc comment.
        /// There is one microphone, so there is one of these.
        let voice: VoiceRecorderController
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
        connection?.sessions.stopPolling()
        tokens.write(nil)
        connection = nil
        lastAuthFailure = detail
        router.rejectToken()
    }

    func signOut() {
        connection?.sessions.stopPolling()
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

        // Weak, and hopped to the main actor: the callback fires from whatever task made the
        // request, and a strong reference here would be a retain cycle through the client the
        // connection holds.
        let client = PaiApiClient(requestFactory: factory) { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleAuthenticationFailure(detail: error.userMessage)
            }
        }
        // Built ahead of the literal rather than inside it: the recorder needs both of these, and
        // a struct literal cannot refer to fields it is still building.
        let settingsStore = SettingsStore(apiClient: client, storage: defaults)
        let draftStore = DraftStore(api: client)

        connection = Connection(
            requestFactory: factory,
            apiClient: client,
            sessions: SessionListStore(api: client),
            machines: MachineStore(api: client),
            transcript: TranscriptStore(),
            settings: settingsStore,
            drafts: draftStore,
            me: MeStore(api: client),
            toasts: ToastCenter(),
            push: PushRegistrationStore(storage: defaults) { token in
                try await client.registerDevice(token: token).token
            },
            voice: VoiceRecorderController(
                apiClient: client, settingsStore: settingsStore, drafts: draftStore)
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
        await connection.me.refresh()
        // Session polling belongs to the app, not to the list screen. Tied to a view it stops
        // the moment a session is opened — so states, titles and warning badges freeze exactly
        // while the user is reading one — and restarting it on return re-fetches the first page,
        // discarding whatever they had scrolled to. The web polls from its root for the same
        // reason.
        connection.sessions.startPolling()
    }

    /// Keep the machine directory current for as long as the app is in front of the user.
    ///
    /// A laptop coming online or going offline is the one thing here that genuinely changes minute
    /// to minute — it decides which machines the launch picker offers, so a stale answer offers a
    /// machine that cannot take the session. The web polls this on its own faster tick for the
    /// same reason; the interval is taken from there rather than picked.
    ///
    /// The loop ends when the task is cancelled, which SwiftUI does when the view it is attached
    /// to goes away.
    func pollMachines() async {
        guard let connection else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            await connection.machines.refresh()
        }
    }
}
