import XCTest

@testable import PAIKit

private actor FakeWakeWordTransport: WakeWordUploadTransport {
    private(set) var calls: [String] = []
    var failing = false
    var goneRuns: Set<String> = []
    var refusedTakes: Set<String> = []

    func setFailing(_ value: Bool) { failing = value }
    func markGone(_ runId: String) { goneRuns.insert(runId) }
    func refuse(_ takeId: String) { refusedTakes.insert(takeId) }

    func putRun(id: String, run: WakeWordRunUpload) async throws {
        if failing { throw PaiError.transport("offline") }
        calls.append("run \(id)")
    }

    func putTake(runId: String, take: WakeWordPendingTake, wav: Data) async throws -> WakeWordTakeUploadOutcome {
        if failing { throw PaiError.transport("offline") }
        if goneRuns.contains(runId) { return .runGone }
        if refusedTakes.contains(take.id) { throw PaiError.detail("take too long", statusCode: 400) }
        calls.append("take \(runId)/\(take.id)")
        return .stored
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FakeTakeFiles: WakeWordTakeFiles, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    func write(_ fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        files[fileName] = Data([1, 2])
    }

    func read(fileName: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return files[fileName]
    }

    func delete(fileName: String) {
        lock.lock()
        defer { lock.unlock() }
        files[fileName] = nil
    }

    var names: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return Set(files.keys)
    }
}

/// The upload queue is the only thing standing between a run recorded offline and the backend
/// corpus — so what it must never do is send out of order, lose a take across a restart, or keep
/// retrying into a run deleted elsewhere.
@MainActor
final class WakeWordUploadQueueTests: XCTestCase {
    private let upload = WakeWordRunUpload(
        kind: .positive, label: "airpods", device: "iPhone · iOS 26", mic: "AirPods", createdAt: "2026-10-03T10:00:00Z")

    private func take(_ id: String, _ index: Int, files: FakeTakeFiles) -> WakeWordPendingTake {
        files.write("\(id).wav")
        return WakeWordPendingTake(
            id: id, index: index, recordedAt: "2026-10-03T10:00:0\(index)Z", durationMs: 700, fileName: "\(id).wav")
    }

    func testTheRunIsStoredBeforeItsTakesAndAFinishedRunLeavesNothingBehind() async {
        let transport = FakeWakeWordTransport()
        let files = FakeTakeFiles()
        let queue = WakeWordUploadQueue(
            storage: SettingsInMemoryKeyValueStore(), transport: transport, files: files, log: { _ in })
        queue.openRun(id: "r1", upload: upload)
        queue.addTake(runId: "r1", take: take("t1", 1, files: files))
        queue.addTake(runId: "r1", take: take("t2", 2, files: files))
        queue.addTake(runId: "r1", take: take("t3", 3, files: files))
        queue.closeRun(id: "r1")

        await queue.drain()

        let calls = await transport.calls
        XCTAssertEqual(calls, ["run r1", "take r1/t1", "take r1/t2", "take r1/t3"])
        XCTAssertTrue(queue.runs.isEmpty)
        XCTAssertTrue(files.names.isEmpty, "a stored take's local audio is deleted")
    }

    func testARunThatNeverRecordedATakeIsNeverStoredAndLeavesNothingBehind() async {
        let transport = FakeWakeWordTransport()
        let queue = WakeWordUploadQueue(
            storage: SettingsInMemoryKeyValueStore(), transport: transport, files: FakeTakeFiles(), log: { _ in })
        queue.openRun(id: "r1", upload: upload)
        await queue.drain()
        let whileOpen = await transport.calls
        XCTAssertEqual(whileOpen, [], "an open run with no take is not stored yet")

        queue.closeRun(id: "r1")
        await queue.drain()
        let afterClose = await transport.calls
        XCTAssertEqual(afterClose, [])
        XCTAssertTrue(queue.runs.isEmpty)
    }

    /// Recorded offline, the app killed, the network back later: the takes are still queued in a
    /// new process and go up then.
    func testWhatFailedToSendSurvivesARestartAndGoesUpLater() async {
        let transport = FakeWakeWordTransport()
        await transport.setFailing(true)
        let files = FakeTakeFiles()
        let storage = SettingsInMemoryKeyValueStore()
        let first = WakeWordUploadQueue(storage: storage, transport: transport, files: files, log: { _ in })
        first.openRun(id: "r1", upload: upload)
        first.addTake(runId: "r1", take: take("t1", 1, files: files))
        first.closeRun(id: "r1")
        await first.drain()
        XCTAssertEqual(first.runs.first?.takes.count, 1)
        XCTAssertNotNil(first.lastError)

        await transport.setFailing(false)
        let second = WakeWordUploadQueue(storage: storage, transport: transport, files: files, log: { _ in })
        XCTAssertEqual(second.runs.map(\.id), ["r1"])
        await second.drain()
        let calls = await transport.calls
        XCTAssertEqual(calls, ["run r1", "take r1/t1"])
        XCTAssertTrue(second.runs.isEmpty)
    }

    /// A run deleted on the web while takes were still queued here: the queue gives up on it,
    /// audio included, and carries on with the next run.
    func testARunGoneOnTheBackendIsDroppedHereWithItsAudio() async {
        let transport = FakeWakeWordTransport()
        await transport.markGone("r1")
        let files = FakeTakeFiles()
        let queue = WakeWordUploadQueue(
            storage: SettingsInMemoryKeyValueStore(), transport: transport, files: files, log: { _ in })
        queue.openRun(id: "r1", upload: upload)
        queue.addTake(runId: "r1", take: take("a", 1, files: files))
        queue.addTake(runId: "r1", take: take("b", 2, files: files))
        queue.openRun(id: "r2", upload: upload)
        queue.addTake(runId: "r2", take: take("c", 1, files: files))
        queue.closeRun(id: "r2")

        await queue.drain()

        XCTAssertEqual(queue.runs.map(\.id), [])
        XCTAssertEqual(files.names, [])
        let calls = await transport.calls
        XCTAssertEqual(calls, ["run r1", "run r2", "take r2/c"])
    }

    /// A take the backend refuses outright (a 400 for a take over its length limit) will be
    /// refused every time: it is dropped, audio included, and logged, instead of blocking every
    /// take behind it.
    func testATakeTheBackendRefusesIsDroppedAndTheNextOneUploads() async {
        let transport = FakeWakeWordTransport()
        await transport.refuse("long")
        let files = FakeTakeFiles()
        let logged = LockedLines()
        let queue = WakeWordUploadQueue(
            storage: SettingsInMemoryKeyValueStore(), transport: transport, files: files, log: { logged.append($0) })
        queue.openRun(id: "r1", upload: upload)
        queue.addTake(runId: "r1", take: take("long", 1, files: files))
        queue.addTake(runId: "r1", take: take("next", 2, files: files))
        queue.closeRun(id: "r1")

        await queue.drain()

        let calls = await transport.calls
        XCTAssertEqual(calls, ["run r1", "take r1/next"])
        XCTAssertTrue(queue.runs.isEmpty)
        XCTAssertTrue(files.names.isEmpty)
        XCTAssertEqual(logged.lines.count, 1)
        XCTAssertTrue(logged.lines[0].contains("long"))
    }

    /// An outage or an expired credential is not a verdict on the take: it stays queued.
    func testAnAuthenticationFailureKeepsTheTakeQueued() async {
        XCTAssertFalse(PaiError.detail("expired", statusCode: 401).isPermanentRejection)
        XCTAssertFalse(PaiError.http(statusCode: 429, reason: "slow down").isPermanentRejection)
        XCTAssertFalse(PaiError.transport("offline").isPermanentRejection)
        XCTAssertTrue(PaiError.detail("too long", statusCode: 400).isPermanentRejection)
    }

    /// An open run whose takes are all up stays queued — more takes are coming.
    func testAnOpenRunStaysQueuedOnceItsTakesAreUp() async {
        let transport = FakeWakeWordTransport()
        let files = FakeTakeFiles()
        let queue = WakeWordUploadQueue(
            storage: SettingsInMemoryKeyValueStore(), transport: transport, files: files, log: { _ in })
        queue.openRun(id: "r1", upload: upload)
        queue.addTake(runId: "r1", take: take("t1", 1, files: files))
        await queue.drain()
        XCTAssertEqual(queue.runs.map(\.id), ["r1"])
        XCTAssertEqual(queue.runs.first?.takes, [])
    }
}
