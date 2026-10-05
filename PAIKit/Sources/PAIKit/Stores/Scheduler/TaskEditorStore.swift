import Foundation
import Observation

public protocol TaskEditorApiClient: Sendable {
    func getSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail
    func createSchedulerTask(fields: TaskWriteFields) async throws -> ScheduledTaskDetail
    func updateSchedulerTask(taskId: String, fields: TaskWriteFields) async throws -> ScheduledTaskDetail
    func deleteSchedulerTask(taskId: String) async throws
    func runSchedulerTaskNow(taskId: String, skipGate: Bool) async throws -> TaskRun
    func resetSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail
    func clearSchedulerTaskStop(taskId: String) async throws -> ScheduledTaskDetail
    func testRunSchedulerGate(
        taskId: String, gateSource: String, gateRuntime: TaskGateRuntime
    ) async throws -> SchedulerTestRunResult
    func getSessionModels() async throws -> SessionModelsResponse
}

extension PaiApiClient: TaskEditorApiClient {}

/// One task's own form — create when `taskId` is `nil`, edit otherwise. Swift port of
/// `TaskEditor.tsx`: one store for both, since every field a create call needs is also an edit
/// call's field (`TaskWriteFields`).
///
/// Never transitions itself from creating to editing after a successful create — the caller
/// (`TaskEditorView`) replaces the route with `.schedulerTask(id: saved.id)`, the same "a new
/// task id is a new screen" rule the web expresses by keying its own `TaskEditor` on `task?.id`.
@MainActor
@Observable
public final class TaskEditorStore {
    public private(set) var task: ScheduledTaskDetail?
    public var fields: TaskWriteFields
    public private(set) var hasGate: Bool
    public private(set) var isLoading: Bool
    public private(set) var isSaving = false
    public private(set) var isBusy = false
    public private(set) var errorMessage: String?

    /// The models, their thinking levels and the supervisor's default model — what the pickers
    /// offer. Empty until `loadCatalog()` lands, in which case no thinking row is shown.
    public private(set) var catalog = SessionModelCatalog()

    public let taskId: String?
    private let api: TaskEditorApiClient

    public init(taskId: String?, api: TaskEditorApiClient, timezone: String) {
        self.taskId = taskId
        self.api = api
        self.fields = .fresh(timezone: timezone)
        self.hasGate = false
        self.isLoading = taskId != nil
    }

    public var isCreating: Bool { taskId == nil }

    /// Standing instructions go out at the top of a conversation's first fire and again only after
    /// a compaction drops them, so an edit does not reach a reused conversation until then — or
    /// until the session is reset. Only `reuse` ever resumes; `fresh`/`oneShot` start a
    /// conversation every fire, so a change there always takes effect.
    public var promptStaleOnEdit: Bool {
        guard let task else { return false }
        return task.sessionPolicy == .reuse && task.sessionId != nil
    }

    public func load() async {
        guard let taskId else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let loaded = try await api.getSchedulerTask(taskId: taskId)
            task = loaded
            fields = .from(loaded)
            hasGate = loaded.gateSource != nil
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not load this task"
        }
    }

    public func loadCatalog() async {
        guard let response = try? await api.getSessionModels() else { return }
        catalog = SessionModelCatalog(response)
    }

    /// The worker's thinking levels for the chosen model. None under "Default" (the plan's own
    /// model takes none) and none on a fast session, which always runs Sonnet.
    public var workerThinkingLevels: [String] {
        fields.environment == "fast" ? [] : catalog.levels(for: fields.model)
    }

    /// Choosing a model drops a thinking level it does not accept — all of them for "Default".
    public func setModel(_ id: String?) {
        fields.model = id
        fields.thinking = catalog.retainedThinking(fields.thinking, model: id)
    }

    public var supervisorThinkingLevels: [String] { catalog.levels(for: fields.supervisionModel) }

    /// Same rule for the supervisor: choosing a model drops a level it does not accept, all of them
    /// for "Default".
    public func setSupervisionModel(_ id: String?) {
        fields.supervisionModel = id
        fields.supervisionThinking = catalog.retainedThinking(fields.supervisionThinking, model: id)
    }

    /// Toggling the gate checkbox on writes an empty script rather than leaving `gateSource` at
    /// its previous value re-armed — mirrors the web's identical `onChange` on the same checkbox.
    public func setHasGate(_ enabled: Bool) {
        hasGate = enabled
        if !enabled {
            fields.gateSource = nil
        } else if fields.gateSource == nil {
            fields.gateSource = ""
        }
    }

    @discardableResult
    public func save() async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        var toSave = fields
        toSave.gateSource = hasGate ? (fields.gateSource ?? "") : nil
        do {
            let saved: ScheduledTaskDetail
            if let taskId {
                saved = try await api.updateSchedulerTask(taskId: taskId, fields: toSave)
            } else {
                saved = try await api.createSchedulerTask(fields: toSave)
            }
            task = saved
            fields = .from(saved)
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not save this task"
            return false
        }
    }

    @discardableResult
    public func delete() async -> Bool {
        guard let taskId else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await api.deleteSchedulerTask(taskId: taskId)
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not delete this task"
            return false
        }
    }

    @discardableResult
    public func runNow(skipGate: Bool = false) async -> Bool {
        await withBusy { taskId in
            _ = try await self.api.runSchedulerTaskNow(taskId: taskId, skipGate: skipGate)
            return try await self.api.getSchedulerTask(taskId: taskId)
        }
    }

    @discardableResult
    public func reset() async -> Bool {
        await withBusy { taskId in try await self.api.resetSchedulerTask(taskId: taskId) }
    }

    @discardableResult
    public func clearStop() async -> Bool {
        await withBusy { taskId in try await self.api.clearSchedulerTaskStop(taskId: taskId) }
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool) async -> Bool {
        var toSave = fields
        toSave.enabled = enabled
        return await withBusy { taskId in try await self.api.updateSchedulerTask(taskId: taskId, fields: toSave) }
    }

    public func testRunGate() async -> SchedulerTestRunResult? {
        guard let taskId, let gateRuntime = fields.gateRuntime else { return nil }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            return try await api.testRunSchedulerGate(
                taskId: taskId, gateSource: fields.gateSource ?? "", gateRuntime: gateRuntime)
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Test run failed"
            return nil
        }
    }

    /// Every already-saved action (run now, reset, clear stop, enable/disable) shares the same
    /// busy/error bookkeeping and the same "refresh `task`/`fields` from what came back" finish —
    /// only the call itself differs.
    private func withBusy(_ action: (String) async throws -> ScheduledTaskDetail) async -> Bool {
        guard let taskId else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            let updated = try await action(taskId)
            task = updated
            fields = .from(updated)
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "That action failed"
            return false
        }
    }
}
