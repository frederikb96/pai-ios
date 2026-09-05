import Foundation
import Observation

public protocol TaskEditorApiClient: Sendable {
    func getSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail
    func createSchedulerTask(fields: TaskWriteFields) async throws -> ScheduledTaskDetail
    func updateSchedulerTask(taskId: String, fields: TaskWriteFields) async throws -> ScheduledTaskDetail
    func deleteSchedulerTask(taskId: String) async throws
    func runSchedulerTaskNow(taskId: String) async throws -> TaskRun
    func resetSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail
    func clearSchedulerTaskStop(taskId: String) async throws -> ScheduledTaskDetail
    func testRunSchedulerGate(
        taskId: String, gateSource: String, gateRuntime: TaskGateRuntime
    ) async throws -> SchedulerTestRunResult
    func createSchedulerWebhook(taskId: String) async throws -> SchedulerWebhookToken
    func revokeSchedulerWebhook(taskId: String) async throws
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
    /// Shown exactly once, right after minting — never shown again, matching the backend's own
    /// "the task itself only ever carries `has_webhook` afterwards" rule.
    public private(set) var mintedWebhookToken: String?

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

    /// Applied at launch only — resuming a task's own conversation cannot pick up a changed
    /// system prompt, so editing it here is a silent no-op until the session is reset. Only
    /// `reuse` ever resumes; `fresh`/`oneShot` relaunch from scratch every fire, so a change
    /// there always takes effect.
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
    public func runNow() async -> Bool {
        await withBusy { taskId in
            _ = try await self.api.runSchedulerTaskNow(taskId: taskId)
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

    public func createWebhook() async {
        guard let taskId else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            mintedWebhookToken = try await api.createSchedulerWebhook(taskId: taskId).token
            await load()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not create a webhook"
        }
    }

    public func revokeWebhook() async {
        guard let taskId else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await api.revokeSchedulerWebhook(taskId: taskId)
            mintedWebhookToken = nil
            await load()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "Could not revoke this webhook"
        }
    }

    public func dismissMintedWebhookToken() {
        mintedWebhookToken = nil
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
