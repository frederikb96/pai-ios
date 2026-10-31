import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol SessionModelApiClient: Sendable {
    func getSessionModels() async throws -> SessionModelsResponse
    func setSessionModel(
        sessionId: String, model: String, thinking: String?
    ) async throws -> SetSessionModelResponse
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
    public private(set) var ultrafastCatalog: UltraFastCatalog?
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
        ultrafastCatalog = response.ultrafast
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
            let result = try await api.setSessionModel(sessionId: sessionId, model: alias, thinking: nil)
            if result.applied == .nextLaunch {
                return .nextLaunch(message: "\(SessionModelSwitch.aliasLabel(alias)) from the session's next start")
            }
            return .switched
        } catch {
            fail(error)
            return .failed
        }
    }

    /// Pins an ultra-fast session to `model` and, when named, `thinking`, from its next reply.
    @discardableResult
    public func chooseUltrafast(model: String, thinking: String?) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await api.setSessionModel(sessionId: sessionId, model: model, thinking: thinking)
            return true
        } catch {
            fail(error)
            return false
        }
    }

    private func fail(_ error: Error) {
        let reason = (error as? PaiError)?.userMessage ?? "Could not reach the server"
        errorMessage = "Couldn't switch the model: \(reason)"
    }
}
