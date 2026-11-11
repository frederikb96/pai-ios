import Foundation
import Observation

/// What a finished grant request tells the person, folded out of the wire's outcomes.
public enum SecretGrantOutcome: Equatable, Sendable {
    case success(String)
    case failure(String)

    public init(_ result: SecretGrantResult) {
        switch result {
        case let .granted(expiresAt, names):
            let covered = names.isEmpty ? "" : " (\(names.joined(separator: ", ")))"
            self = .success("Granted gated-secret access\(covered) until \(Self.formatted(expiresAt))")
        case .pending:
            self = .success("Secrets will be granted once the session is ready")
        case .wrongPassphrase:
            self = .failure("Wrong passphrase.")
        case .sessionUnavailable:
            self = .failure("This session isn't running right now — nothing to grant access to.")
        case .nothingRequested:
            self = .failure("Nothing to grant anymore — the agent isn't waiting on a gated secret.")
        case let .notAuthorized(message), let .rateLimited(message), let .invalidRequest(message):
            self = .failure(message)
        case .timedOut:
            self = .failure("The agent didn't answer in time. Try again.")
        }
    }

    /// The backend's six-fractional-digit ISO timestamp needs `IsoTimestamp`; the raw string is
    /// shown if parsing fails rather than hiding the expiry.
    private static func formatted(_ raw: String) -> String {
        guard let date = IsoTimestamp.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Runs a secret grant after the sheet that collected it has closed, so the person can move on
/// while the unlock takes its seconds. App-wide, because the request must outlive both the sheet
/// and the session screen.
///
/// Success is a toast wherever the person is by then. A failure is kept per session until a grant
/// sheet for it takes it (`takeFailure`): a composer showing that session re-presents the sheet at
/// once, and when none is showing the error toast's action opens the session, whose composer then
/// does. The session's own prompt stays pending on the server, so the sheet comes back as it was.
///
/// 🚨 The passphrase is a parameter of `start` and lives only inside the request's task; nothing
/// here stores it.
@MainActor
@Observable
public final class SecretGrantRunStore {
    public typealias Grant =
        @Sendable (_ sessionId: String, _ passphrase: String, _ ttlSeconds: Int, _ scope: SecretGrantScope)
        async throws -> SecretGrantResult

    /// Sessions with a grant request in flight, so a sheet reopened meanwhile shows it busy.
    public private(set) var inFlight: Set<String> = []
    /// Why the last grant for a session failed, until a sheet for it has shown it.
    public private(set) var failures: [String: String] = [:]
    /// Opens a session's screen; what a failure toast's action calls.
    @ObservationIgnored public var openSession: (@MainActor @Sendable (String) -> Void)?

    @ObservationIgnored private let grant: Grant
    @ObservationIgnored private var presentComposers: [String: Int] = [:]

    public init(grant: @escaping Grant) {
        self.grant = grant
    }

    /// A composer for `sessionId` is on screen and re-presents the grant sheet itself on a failure.
    public func composerAppeared(sessionId: String) {
        presentComposers[sessionId, default: 0] += 1
    }

    public func composerDisappeared(sessionId: String) {
        let remaining = (presentComposers[sessionId] ?? 0) - 1
        presentComposers[sessionId] = remaining > 0 ? remaining : nil
    }

    /// Returns the pending failure for `sessionId` and forgets it.
    public func takeFailure(sessionId: String) -> String? {
        failures.removeValue(forKey: sessionId)
    }

    /// Fires the grant and returns at once. A second request for a session already in flight is
    /// ignored.
    public func start(
        sessionId: String, passphrase: String, ttlSeconds: Int, scope: SecretGrantScope, toasts: ToastCenter
    ) {
        guard !inFlight.contains(sessionId) else { return }
        inFlight.insert(sessionId)
        failures[sessionId] = nil
        let grant = grant
        Task { [weak self, weak toasts] in
            let outcome: SecretGrantOutcome
            do {
                outcome = SecretGrantOutcome(
                    try await grant(sessionId, passphrase, ttlSeconds, scope))
            } catch {
                outcome = .failure((error as? PaiError)?.userMessage ?? "Could not grant access")
            }
            self?.finish(sessionId: sessionId, outcome: outcome, toasts: toasts)
        }
    }

    private func finish(sessionId: String, outcome: SecretGrantOutcome, toasts: ToastCenter?) {
        inFlight.remove(sessionId)
        switch outcome {
        case let .success(text):
            toasts?.show(text, kind: .success)
        case let .failure(message):
            failures[sessionId] = message
            guard presentComposers[sessionId] == nil else { return }
            let open = openSession
            toasts?.show(
                "Secret grant failed: \(message)", kind: .error,
                action: open.map { open in
                    ToastMessage.Action(label: "Open") { open(sessionId) }
                })
        }
    }
}
