import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client. The conformance is declared
/// here, next to the protocol it satisfies.
public protocol ClaudeAuthApiClient: Sendable {
    func getClaudeAuth() async throws -> ClaudeAuth
    func startClaudeLogin() async throws -> ClaudeAuth
    func submitClaudeLoginCode(loginId: String, code: String) async throws -> ClaudeLoginCodeResponse
    func cancelClaudeLogin() async throws -> ClaudeAuth
}

extension PaiApiClient: ClaudeAuthApiClient {}

/// Pure predicates over a `ClaudeAuth` snapshot — Swift port of `pai-cloud/web/src/stores/
/// claudeAuth.ts`'s free functions, kept separate from the store's polling machinery so a view or
/// a test can reason about "what does this snapshot mean" on its own.
public enum ClaudeAuthPredicates {

    /// Warn this far ahead of the point where a real sign-in becomes unavoidable. Mirrors the
    /// web's `EXPIRY_WARNING_MS`: three days rather than one because the work being warned about
    /// is manual and roughly monthly, and a day's notice that lands overnight is first read as an
    /// outage.
    public static let expiryWarningMs: Double = 3 * 24 * 60 * 60 * 1000

    /// Poll cadence while the VM is signed in and nothing needs doing.
    public static let idlePollNanos: UInt64 = 60_000_000_000
    /// Poll cadence while signed out or mid-sign-in — the agent can produce a link, or another
    /// device can finish the sign-in, at any moment, and the screen must not be stale.
    public static let activePollNanos: UInt64 = 3_000_000_000

    /// True when the credential is close enough to its hard expiry to be worth warning about. An
    /// unreported expiry is never a warning — the VM not saying when it expires is not the same
    /// as it expiring soon.
    public static func expiresWithinWarning(_ auth: ClaudeAuth, now: Double) -> Bool {
        guard let expiresAt = auth.refreshExpiresAt else { return false }
        return expiresAt - now < expiryWarningMs
    }

    /// Whether the VM cannot launch a session until somebody signs in.
    ///
    /// Deliberately derived from `loggedIn` and nothing else — comparing `refreshExpiresAt`
    /// against the clock instead is what let the web banner stay silent through an outage where
    /// the *access* token had died, every request came back 401, and the refresh token was still
    /// a month from expiring. There is exactly one authority on this question and it is the
    /// agent; see `ClaudeAuth`'s own doc comment.
    public static func needsSignIn(_ auth: ClaudeAuth) -> Bool {
        auth.known && auth.loggedIn == false
    }

    /// True while the credential exists and is simply being refused. Only changes the wording —
    /// every consequence is the same as being signed out.
    public static func isRejected(_ auth: ClaudeAuth) -> Bool {
        needsSignIn(auth) && auth.health == .rejected
    }

    /// How long to wait before the next poll, given what the last snapshot said.
    public static func pollInterval(_ auth: ClaudeAuth) -> UInt64 {
        let active = auth.known && (auth.loggedIn != true || auth.login != nil)
        return active ? activePollNanos : idlePollNanos
    }

    /// "under an hour", "6 hours", "3 days" — the expiry warning's own wording, ported verbatim
    /// from the web's `formatTimeUntil` rather than left to a system formatter, since the exact
    /// phrasing is part of what the brief asked to match.
    public static func formatTimeUntil(_ ms: Double) -> String {
        guard ms > 0 else { return "now" }
        let hours = Int(ms / 3_600_000)
        if hours < 1 { return "under an hour" }
        if hours < 48 { return "\(hours) hour\(hours == 1 ? "" : "s")" }
        let days = Int((Double(hours) / 24).rounded())
        return "\(days) days"
    }
}

/// Swift port of `claudeAuth.ts`'s store half: the VM's one Claude credential, polled at a
/// cadence that follows its own state, plus the three calls that walk a fresh sign-in from a link
/// to a pasted code.
///
/// Read `auth` through `ClaudeAuthPredicates` rather than inline in a view — the predicates are
/// what a test proves, and a view that re-derives the same logic is the shape that drifts from
/// them silently.
@MainActor
@Observable
public final class ClaudeAuthStore {
    public private(set) var auth = ClaudeAuth(
        known: false, loggedIn: nil, subscription: nil, accessExpiresAt: nil,
        refreshExpiresAt: nil, login: nil, lastError: nil, reportedAt: nil
    )
    /// A sign-in start or code submission is in flight from this device.
    public private(set) var busy = false
    /// The last code rejection, cleared as soon as another attempt begins.
    public private(set) var codeError: String?

    private let api: ClaudeAuthApiClient
    private var pollTask: Task<Void, Never>?

    public init(api: ClaudeAuthApiClient) {
        self.api = api
    }

    /// A pod that cannot answer is not evidence about the VM's credential — leaving the previous
    /// snapshot in place keeps a transient blip from flashing a sign-in alarm at someone who is
    /// signed in fine.
    public func refresh() async {
        guard let fetched = try? await api.getClaudeAuth() else { return }
        auth = fetched
    }

    /// Idempotent — a second call while one is already running does nothing. The cadence is
    /// re-derived from `auth` after every fetch rather than fixed, so a sign-in link appearing
    /// mid-poll is picked up within seconds rather than up to a minute later.
    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: ClaudeAuthPredicates.pollInterval(self.auth))
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    public func startLogin() async {
        busy = true
        codeError = nil
        defer { busy = false }
        do {
            auth = try await api.startClaudeLogin()
        } catch {
            codeError = (error as? PaiError)?.userMessage ?? "Could not start the sign-in"
        }
    }

    /// The caller passes the id of the link it actually rendered, not whatever the latest poll
    /// happens to hold: the attempt can be replaced between opening the page and pasting the code
    /// (another device started over, the agent restarted), and submitting against the wrong one
    /// burns a second attempt and tells the user nothing useful.
    @discardableResult
    public func submitCode(loginId: String, code: String) async -> Bool {
        guard auth.login?.id == loginId else {
            codeError = "That link was replaced — open the new one and try again"
            return false
        }
        busy = true
        codeError = nil
        defer { busy = false }
        do {
            let result = try await api.submitClaudeLoginCode(loginId: loginId, code: code)
            auth = result.auth
            codeError = result.ok ? nil : (result.error ?? "That code was rejected")
            return result.ok
        } catch {
            codeError = (error as? PaiError)?.userMessage ?? "Could not submit the code"
            return false
        }
    }

    public func cancelLogin() async {
        busy = true
        codeError = nil
        defer { busy = false }
        // Nothing useful to say on failure — the next poll re-establishes the truth.
        auth = (try? await api.cancelClaudeLogin()) ?? auth
    }
}
