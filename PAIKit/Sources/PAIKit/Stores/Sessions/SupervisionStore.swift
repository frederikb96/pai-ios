import Foundation
import Observation

/// The narrow slice of `PaiApiClient` this store needs.
public protocol SupervisionApiClient: Sendable {
    func getSupervisionBySession(sessionId: String) async throws -> SupervisionBySessionResponse
    func getSupervision(supervisionId: String) async throws -> SupervisionDetail
    func attachSupervision(sessionId: String, config: SupervisionConfigFields) async throws -> Supervision
    func deleteSupervision(supervisionId: String) async throws -> PaiSupervisionDetachResult
}

extension PaiApiClient: SupervisionApiClient {}

/// A session's own supervisor — open from its menu, attach with the same controls the scheduler
/// task editor offers, or read its state and verdict history and detach it. Swift port of the
/// web's `SupervisorPanel`.
///
/// Read-only once attached: this store never edits a LIVE supervision's own configuration — that
/// stays the scheduler's own configuration screen's job. `config` here is only ever the draft for
/// an attach (or re-attach) call, never a live edit.
@MainActor
@Observable
public final class SupervisionStore {
    /// The binding as last fetched — `nil` before anything has ever been attached. Once attached,
    /// `state == .ended` (a detach happened) still leaves this non-nil: the backend keeps the row
    /// and its history, so `needsAttach` is what a view actually branches on, never `detail ==
    /// nil` alone.
    public private(set) var detail: SupervisionDetail?
    /// The attach form's own draft — pre-filled from `detail`'s own configuration once loaded
    /// (including an `ended` one, so re-attaching starts from the previous configuration rather
    /// than a blank form), editable from there for a fresh attach.
    public var config: SupervisionConfigFields = .empty
    public private(set) var isLoading = true
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    public let sessionId: String
    private let api: SupervisionApiClient

    public init(sessionId: String, api: SupervisionApiClient) {
        self.sessionId = sessionId
        self.api = api
    }

    /// Nothing is currently watching this session — either it was never attached, or the
    /// previous one was detached. The backend allows re-attaching in either case and refuses
    /// (409) only while one is genuinely active, so this is what a view should branch its
    /// attach-form-vs-read-only-panel decision on, never `detail == nil` alone.
    public var needsAttach: Bool { detail == nil || detail?.state == .ended }

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
            let full = try await api.getSupervision(supervisionId: supervision.id)
            detail = full
            config = .from(full)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not check for a supervisor"
        }
    }

    /// Attaches (or re-attaches) using the current `config` draft.
    public func attach() async -> Bool {
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let created = try await api.attachSupervision(sessionId: sessionId, config: config)
            detail = SupervisionDetail(
                id: created.id, workerSessionId: created.workerSessionId, taskId: created.taskId,
                state: created.state, memo: created.memo, cursorMessageId: created.cursorMessageId,
                model: created.model, appendPrompt: created.appendPrompt,
                compactionThresholdTokens: created.compactionThresholdTokens,
                chunkIntervalSeconds: created.chunkIntervalSeconds,
                chunkTokenThreshold: created.chunkTokenThreshold,
                supervisorSessionId: created.supervisorSessionId, createdAtMs: created.createdAtMs,
                updatedAtMs: created.updatedAtMs, verdicts: nil)
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
            // The backend keeps the row (state `ended`) rather than deleting it — reloading
            // rather than clearing `detail` locally is what lets a later re-attach still see the
            // same row's own history if the view ever wants it, and matches what the web does
            // (it navigates away instead, but the underlying state is the same: `ended`, not
            // gone).
            await load()
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not detach the supervisor"
            return false
        }
    }
}
