import Foundation
import Observation

/// The one call `OutboxStore` needs — narrowed so a test can fake it without the stub
/// `URLProtocol` machinery `PaiApiClient` itself is tested with.
public protocol OutboxSending: Sendable {
    func postMessage(
        sessionId: String?, message: String, clientMessageId: String, files: [PaiFileUpload],
        draftAttachmentIds: [String], sessionType: String?, workingDir: String?, agent: String?, model: String?,
        thinking: String?, clientMode: String?
    ) async throws -> PostMessageResponse
}

extension PaiApiClient: OutboxSending {}

/// A durable, exactly-once send queue. Swift port of the web's own `stores/outbox.ts` design:
/// persisted before the composer that produced it is ever cleared, one FIFO worker per target
/// (a session, or the not-yet-created "new" session), retried with backoff, and resumed on
/// restart from whatever ``OutboxStorage`` already has on disk.
///
/// **The optimistic bubble a caller renders is this store's own `entries`, not a second,
/// in-memory tracker** — it exists before any request leaves and survives a reload, because the
/// entry it is built from does. `TranscriptStore`'s own `pending_sends`/`outbox_id` machinery
/// takes over the moment the transcript confirms the send; this store's job ends at "the server
/// has the row".
///
/// `@MainActor`, matching every other store here — every realistic caller is UI-driven, and the
/// entry count is nowhere near where hopping onto the main actor per call would cost anything.
@MainActor
@Observable
public final class OutboxStore {

    /// 1s → 2 → 4 → … capped at 60s — frequent enough that a dropped request heals within
    /// seconds, capped low enough that a genuinely offline device is not hammering the server for
    /// the rest of a session.
    public static let retryBaseSeconds: TimeInterval = 1
    public static let retryMaxSeconds: TimeInterval = 60

    public private(set) var entries: [OutboxEntry] = []

    private let api: any OutboxSending
    private let storage: any OutboxStorage
    private let scheduler: DraftScheduler
    /// Called once an entry actually reaches the server — the caller's hook to clear the draft it
    /// came from, insert the session it created, and do nothing else: everything past "the server
    /// has the row" belongs to the transcript's own delivery tracking.
    public var onSent: (@MainActor (OutboxEntry) -> Void)?

    /// One loop per ``OutboxTarget/workerKey`` — FIFO within a target, matching the server
    /// outbox's own per-target ordering. `nil` once a worker finds nothing left to do; a fresh
    /// enqueue restarts it.
    private var workers: [String: Task<Void, Never>] = [:]
    /// The backoff sleep currently outstanding for an entry, if any — what ``retryNow()``
    /// cancels. Cancelling only the sleep, never the worker loop around it, is what lets "skip
    /// the wait" never race a send already in flight: an entry mid-request has no task in here
    /// to cancel at all, so a wake during a real attempt is simply a no-op for it.
    private var backoffTasks: [String: Task<Void, Never>] = [:]

    public init(api: some OutboxSending, storage: some OutboxStorage, scheduler: DraftScheduler = RealDraftScheduler())
    {
        self.api = api
        self.storage = storage
        self.scheduler = scheduler
        var loaded = storage.loadEntries()
        // An entry found `sending` at startup was mid-flight when the process ended — the POST is
        // idempotent on `clientMessageId`, so resending it is safe, and is the whole point: this
        // is what makes a send survive an app kill.
        for index in loaded.indices where loaded[index].state == .sending {
            loaded[index].state = .queued
        }
        entries = loaded
        storage.saveEntries(loaded)
        for key in Set(loaded.filter { $0.state == .queued }.map(\.target.workerKey)) {
            ensureWorker(for: key)
        }
    }

    /// The entries to show for a target, oldest first — a composer's own pending-bubble list.
    public func entries(for sessionId: String) -> [OutboxEntry] {
        entries.filter { $0.target.sessionId == sessionId }
    }

    public func newSessionEntries() -> [OutboxEntry] {
        entries.filter { $0.target.sessionId == nil }
    }

    /// Writes the entry to disk **before** returning — the composer clears itself only after this
    /// call, which is what makes the bubble exist, and survive a kill, before any request has
    /// left. `inlineFiles`' bytes are written to ``OutboxStorage`` here too, once, rather than
    /// re-read from wherever the caller staged them on every retry.
    public func enqueue(_ entry: OutboxEntry, inlineFileData: [String: Data] = [:]) {
        entries.append(entry)
        persist()
        for (localId, data) in inlineFileData {
            storage.writeInlineFile(data, localId: localId)
        }
        ensureWorker(for: entry.target.workerKey)
    }

    /// Re-queues a `.failed` entry under the same `clientMessageId` — never a new one, or the
    /// server would see it as an unrelated send rather than a retry of the same one.
    public func retry(id: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .queued
        entries[index].lastError = nil
        persist()
        ensureWorker(for: entries[index].target.workerKey)
    }

    /// Removes an entry outright — Discard on a failed send. Never used on anything still
    /// `queued`/`sending`; a caller that wants to abandon an in-flight send has nothing to
    /// cancel it with (the request may already be on the wire) and must wait for it to resolve.
    public func discard(id: String) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        storage.removeInlineFiles(localIds: entry.inlineFiles.map(\.localId))
        persist()
    }

    /// "On path satisfied, attempt immediately" — skips whatever backoff a worker is waiting out.
    /// An entry currently mid-request (no backoff task registered for it) is left alone; only a
    /// genuinely idle wait is cut short.
    public func retryNow() {
        for task in backoffTasks.values { task.cancel() }
    }

    private func persist() {
        storage.saveEntries(entries)
    }

    // MARK: - Workers

    private func ensureWorker(for key: String) {
        guard workers[key] == nil else { return }
        workers[key] = Task { [weak self] in await self?.runWorker(key: key) }
    }

    private func runWorker(key: String) async {
        while true {
            guard let index = entries.firstIndex(where: { $0.target.workerKey == key && $0.state == .queued }) else {
                workers[key] = nil
                return
            }
            await attemptSend(at: index)
        }
    }

    private func attemptSend(at index: Int) async {
        let entry = entries[index]
        entries[index].state = .sending
        persist()

        let files = entry.inlineFiles.compactMap { file -> PaiFileUpload? in
            guard let data = storage.readInlineFile(localId: file.localId) else { return nil }
            return PaiFileUpload(filename: file.filename, mimeType: file.mimeType, data: data)
        }

        do {
            let response = try await api.postMessage(
                sessionId: entry.target.sessionId, message: entry.text, clientMessageId: entry.clientMessageId,
                files: files, draftAttachmentIds: entry.draftAttachmentIds, sessionType: entry.target.sessionType,
                workingDir: entry.target.workingDir, agent: entry.target.agent, model: entry.target.model,
                thinking: entry.target.thinking, clientMode: entry.clientMode
            )
            guard let current = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            entries[current].state = .sent
            entries[current].result = OutboxResult(sessionId: response.sessionId, messageId: response.messageId)
            storage.removeInlineFiles(localIds: entry.inlineFiles.map(\.localId))
            persist()
            onSent?(entries[current])
        } catch {
            guard let current = entries.firstIndex(where: { $0.id == entry.id }) else { return }
            if Self.isRetryable(error) {
                entries[current].state = .queued
                entries[current].attempts += 1
                entries[current].lastError = Self.describe(error)
                persist()
                let attempt = entries[current].attempts
                let delay = min(Self.retryBaseSeconds * pow(2, Double(attempt - 1)), Self.retryMaxSeconds)
                let id = entry.id
                let sleepTask = Task { [scheduler] in _ = try? await scheduler.sleep(seconds: delay) }
                backoffTasks[id] = sleepTask
                await sleepTask.value
                backoffTasks[id] = nil
            } else {
                entries[current].state = .failed
                entries[current].lastError = Self.describe(error)
                persist()
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let paiError = error as? PaiError else { return true }
        if paiError.isSessionNotActive { return true }
        switch paiError {
        case let .detail(_, statusCode), let .http(statusCode, _):
            return statusCode >= 500 || statusCode == 429
        case .transport:
            return true
        case .decoding:
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? PaiError)?.userMessage ?? "\(error)"
    }
}
