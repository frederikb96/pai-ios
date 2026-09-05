import Foundation
@testable import PAIKit

/// Fakes shared by the `Scheduler*StoreTests` files — same shape as `SessionStoreFakes.swift`:
/// one actor per protocol, scriptable results, and a call log a test can read back.

actor FakeSchedulerListApi: SchedulerListApiClient {
    var result: Result<SchedulerTaskListResponse, PaiError> = .success(
        SchedulerTaskListResponse(tasks: [], nextOffset: nil))

    func setResult(_ result: Result<SchedulerTaskListResponse, PaiError>) {
        self.result = result
    }

    func listSchedulerTasks(limit: Int?, offset: Int?) async throws -> SchedulerTaskListResponse {
        switch result {
        case let .success(page): return page
        case let .failure(error): throw error
        }
    }
}

actor FakeTaskEditorApi: TaskEditorApiClient {
    private(set) var createCalls: [TaskWriteFields] = []
    private(set) var updateCalls: [(taskId: String, fields: TaskWriteFields)] = []
    private(set) var deleteCalls: [String] = []
    private(set) var runNowCalls: [String] = []
    private(set) var resetCalls: [String] = []
    private(set) var clearStopCalls: [String] = []

    var getResult: Result<ScheduledTaskDetail, PaiError>?
    var createResult: Result<ScheduledTaskDetail, PaiError>?
    var updateResult: Result<ScheduledTaskDetail, PaiError>?
    var deleteResult: Result<Void, PaiError> = .success(())
    var runNowResult: Result<TaskRun, PaiError>?
    var resetResult: Result<ScheduledTaskDetail, PaiError>?
    var clearStopResult: Result<ScheduledTaskDetail, PaiError>?
    var testRunResult: Result<SchedulerTestRunResult, PaiError>?
    var createWebhookResult: Result<SchedulerWebhookToken, PaiError>?
    var revokeWebhookResult: Result<Void, PaiError> = .success(())

    func setGetResult(_ result: Result<ScheduledTaskDetail, PaiError>) { getResult = result }
    func setCreateResult(_ result: Result<ScheduledTaskDetail, PaiError>) { createResult = result }
    func setUpdateResult(_ result: Result<ScheduledTaskDetail, PaiError>) { updateResult = result }

    func getSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail {
        guard let getResult else { throw PaiError.transport("no getResult scripted") }
        switch getResult {
        case let .success(task): return task
        case let .failure(error): throw error
        }
    }

    func createSchedulerTask(fields: TaskWriteFields) async throws -> ScheduledTaskDetail {
        createCalls.append(fields)
        guard let createResult else { throw PaiError.transport("no createResult scripted") }
        switch createResult {
        case let .success(task): return task
        case let .failure(error): throw error
        }
    }

    func updateSchedulerTask(taskId: String, fields: TaskWriteFields) async throws -> ScheduledTaskDetail {
        updateCalls.append((taskId: taskId, fields: fields))
        guard let updateResult else { throw PaiError.transport("no updateResult scripted") }
        switch updateResult {
        case let .success(task): return task
        case let .failure(error): throw error
        }
    }

    func deleteSchedulerTask(taskId: String) async throws {
        deleteCalls.append(taskId)
        if case let .failure(error) = deleteResult { throw error }
    }

    func runSchedulerTaskNow(taskId: String) async throws -> TaskRun {
        runNowCalls.append(taskId)
        guard let runNowResult else { throw PaiError.transport("no runNowResult scripted") }
        switch runNowResult {
        case let .success(run): return run
        case let .failure(error): throw error
        }
    }

    func resetSchedulerTask(taskId: String) async throws -> ScheduledTaskDetail {
        resetCalls.append(taskId)
        guard let resetResult else { throw PaiError.transport("no resetResult scripted") }
        switch resetResult {
        case let .success(task): return task
        case let .failure(error): throw error
        }
    }

    func clearSchedulerTaskStop(taskId: String) async throws -> ScheduledTaskDetail {
        clearStopCalls.append(taskId)
        guard let clearStopResult else { throw PaiError.transport("no clearStopResult scripted") }
        switch clearStopResult {
        case let .success(task): return task
        case let .failure(error): throw error
        }
    }

    func testRunSchedulerGate(
        taskId: String, gateSource: String, gateRuntime: TaskGateRuntime
    ) async throws -> SchedulerTestRunResult {
        guard let testRunResult else { throw PaiError.transport("no testRunResult scripted") }
        switch testRunResult {
        case let .success(result): return result
        case let .failure(error): throw error
        }
    }

    func createSchedulerWebhook(taskId: String) async throws -> SchedulerWebhookToken {
        guard let createWebhookResult else { throw PaiError.transport("no createWebhookResult scripted") }
        switch createWebhookResult {
        case let .success(token): return token
        case let .failure(error): throw error
        }
    }

    func revokeSchedulerWebhook(taskId: String) async throws {
        if case let .failure(error) = revokeWebhookResult { throw error }
    }
}

actor FakeRunHistoryApi: RunHistoryApiClient {
    private(set) var calls: [(taskId: String, limit: Int?, offset: Int?)] = []
    /// Pages returned in order, one per call — lets a test script exactly what each successive
    /// `loadMore()` sees without re-deriving offsets itself.
    var pages: [Result<SchedulerTaskRunsResponse, PaiError>] = []

    func setPages(_ pages: [Result<SchedulerTaskRunsResponse, PaiError>]) {
        self.pages = pages
    }

    func listSchedulerTaskRuns(taskId: String, limit: Int?, offset: Int?) async throws -> SchedulerTaskRunsResponse {
        calls.append((taskId: taskId, limit: limit, offset: offset))
        guard !pages.isEmpty else { return SchedulerTaskRunsResponse(runs: [], nextOffset: nil) }
        switch pages.removeFirst() {
        case let .success(page): return page
        case let .failure(error): throw error
        }
    }
}
