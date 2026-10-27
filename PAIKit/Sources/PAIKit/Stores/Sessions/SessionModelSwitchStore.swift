import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol SessionModelApiClient: Sendable {
    func getSessionModels() async throws -> SessionModelsResponse
    func setSessionModel(sessionId: String, model: String) async throws -> SetSessionModelResponse
}

extension PaiApiClient: SessionModelApiClient {}

/// The picker behind the header's model badge: lists the models the server offers and switches
/// one session to a chosen alias. The badge itself moves from the status stream the route
/// triggers, so nothing is written to the session list here.
@MainActor
@Observable
public final class SessionModelSwitchStore {
    public enum Outcome: Equatable, Sendable {
        /// The chosen alias is already the session's; nothing was sent.
        case unchanged
        /// The running process switched.
        case switched
        /// The session is closed; the alias applies when it next launches. Carries the text the
        /// reader should see once the picker is gone.
        case nextLaunch(message: String)
        case failed
    }

    public private(set) var catalog = SessionModelCatalog()
    public private(set) var isBusy = false
    /// The server's own words for the last refusal, shown inside the picker (a toast would sit
    /// beneath it).
    public private(set) var errorMessage: String?

    public let sessionId: String
    private let api: SessionModelApiClient

    public init(sessionId: String, api: SessionModelApiClient) {
        self.sessionId = sessionId
        self.api = api
    }

    public func load() async {
        guard let response = try? await api.getSessionModels() else { return }
        catalog = SessionModelCatalog(response)
    }

    /// Switches to `alias`. `current` is what the badge already runs on (`SessionModelSwitch
    /// .currentAlias`).
    public func choose(_ alias: String, current: String?) async -> Outcome {
        guard !isBusy else { return .failed }
        guard alias != current else { return .unchanged }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let result = try await api.setSessionModel(sessionId: sessionId, model: alias)
            if result.applied == .nextLaunch {
                return .nextLaunch(message: "\(SessionModelSwitch.aliasLabel(alias)) from the session's next start")
            }
            return .switched
        } catch {
            let reason = (error as? PaiError)?.userMessage ?? "Could not reach the server"
            errorMessage = "Couldn't switch the model: \(reason)"
            return .failed
        }
    }
}
