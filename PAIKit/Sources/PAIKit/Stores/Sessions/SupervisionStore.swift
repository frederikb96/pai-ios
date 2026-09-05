import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol SupervisionApiClient: Sendable {
    func getSupervisionBySession(sessionId: String) async throws -> SupervisionBySessionResponse
    func getSupervision(supervisionId: String) async throws -> SupervisionDetail
    func attachSupervision(
        sessionId: String, model: String?, appendPrompt: String?, compactionThresholdTokens: Int?,
        chunkIntervalSeconds: Int?, chunkTokenThreshold: Int?
    ) async throws -> Supervision
    func deleteSupervision(supervisionId: String) async throws -> PaiSupervisionDetachResult
}

extension PaiApiClient: SupervisionApiClient {}

/// A session's own supervisor — open, read-only, from its menu. Swift port of the same
/// session-menu control the web is building alongside this: fetch what is watching the session,
/// if anything, and offer to attach one or detach the existing one.
///
/// Read-only by design: this store never edits a supervision's own configuration once attached —
/// the row's own verification names that as the scheduler's own configuration screen's job, not
/// a session menu's.
@MainActor
@Observable
public final class SupervisionStore {
    public private(set) var detail: SupervisionDetail?
    public private(set) var isLoading = true
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    public let sessionId: String
    private let api: SupervisionApiClient

    public init(sessionId: String, api: SupervisionApiClient) {
        self.sessionId = sessionId
        self.api = api
    }

    /// Fetches the binding, then its full detail (state, configuration, verdict history) — two
    /// calls because `by-session` exists precisely so a menu button can ask "is there one at all"
    /// without paying for a verdict history most sessions have none of.
    public func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await api.getSupervisionBySession(sessionId: sessionId)
            guard let supervision = response.supervision else {
                detail = nil
                return
            }
            detail = try await api.getSupervision(supervisionId: supervision.id)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not check for a supervisor"
        }
    }

    /// Attaches with a model choice only — every other configuration field is the scheduler's own
    /// configuration screen's job to pre-fill, not this menu's to expose.
    public func attach(model: String?) async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let created = try await api.attachSupervision(
                sessionId: sessionId, model: model, appendPrompt: nil, compactionThresholdTokens: nil,
                chunkIntervalSeconds: nil, chunkTokenThreshold: nil)
            detail = SupervisionDetail(
                id: created.id, workerSessionId: created.workerSessionId, taskId: created.taskId,
                state: created.state, memo: created.memo, cursorMessageId: created.cursorMessageId,
                model: created.model, appendPrompt: created.appendPrompt,
                compactionThresholdTokens: created.compactionThresholdTokens,
                chunkIntervalSeconds: created.chunkIntervalSeconds,
                chunkTokenThreshold: created.chunkTokenThreshold, createdAtMs: created.createdAtMs,
                updatedAtMs: created.updatedAtMs, supervisorSessionId: nil, verdicts: nil)
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not attach a supervisor"
            return false
        }
    }

    public func detach() async -> Bool {
        guard let id = detail?.id else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            _ = try await api.deleteSupervision(supervisionId: id)
            detail = nil
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not detach the supervisor"
            return false
        }
    }
}
