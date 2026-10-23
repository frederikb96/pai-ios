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

/// How a task becomes due: a recurring cadence, one instant, or only by hand. The wire carries
/// this as which of `cadence`/`run_at` is set; the form holds it separately so switching back and
/// forth does not lose what was typed into either.
public enum TaskScheduleMode: Sendable, Equatable, CaseIterable {
    case cadence, once, manual

    static func of(cadence: String?, runAt: String?) -> TaskScheduleMode {
        if runAt != nil { return .once }
        return cadence != nil ? .cadence : .manual
    }
}

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
    public private(set) var scheduleMode: TaskScheduleMode
    /// The instant a `.once` task fires at, as the date picker edits it. Shown in the task's own
    /// timezone (``pickerTimeZone``), so the wall time picked is the one meant there.
    public var runAtDate: Date

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
        self.scheduleMode = .manual
        self.runAtDate = Self.nextHour(after: Date())
    }

    /// The task's own timezone, which the run-time picker shows its wall time in; the device's
    /// while the field holds a name this platform does not know.
    public var pickerTimeZone: TimeZone { TimeZone(identifier: fields.timezone) ?? .current }

    /// A one-time run keeps its conversation for the user to resume, which the one-shot policy
    /// would delete — the server refuses the pair, so choosing `.once` moves off it.
    public func setScheduleMode(_ mode: TaskScheduleMode) {
        scheduleMode = mode
        if mode == .once && fields.sessionPolicy == .oneShot { fields.sessionPolicy = .fresh }
    }

    private func adopt(_ loaded: ScheduledTaskDetail) {
        task = loaded
        fields = .from(loaded)
        scheduleMode = .of(cadence: loaded.cadence, runAt: loaded.runAt)
        if let runAt = loaded.runAt, let date = IsoTimestamp.date(from: runAt) { runAtDate = date }
    }

    private static func nextHour(after date: Date) -> Date {
        let hour = 3600.0
        return Date(timeIntervalSince1970: ((date.timeIntervalSince1970 / hour).rounded(.down) + 1) * hour)
    }

    /// The instant as the API takes it, whole minutes in UTC — the picker edits hours and minutes
    /// and would otherwise carry the seconds of whatever date it started from.
    static func wireInstant(_ date: Date) -> String {
        let minute = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: minute))
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
            adopt(loaded)
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
        switch scheduleMode {
        case .cadence:
            toSave.runAt = nil
        case .once:
            toSave.cadence = nil
            toSave.runAt = Self.wireInstant(runAtDate)
        case .manual:
            toSave.cadence = nil
            toSave.runAt = nil
        }
        do {
            let saved: ScheduledTaskDetail
            if let taskId {
                saved = try await api.updateSchedulerTask(taskId: taskId, fields: toSave)
            } else {
                saved = try await api.createSchedulerTask(fields: toSave)
            }
            adopt(saved)
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
            adopt(try await action(taskId))
            return true
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "That action failed"
            return false
        }
    }
}
