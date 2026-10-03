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

/// What Undo send needs from the server, kept out of ``OutboxSending``'s required members so a
/// sender that only ever posts (a test double) need not pretend to withdraw. ``OutboxStore`` asks
/// for it by cast, and a sender without it is treated exactly like a withdraw request that
/// failed: everything that may be on the server is left alone.
public protocol OutboxWithdrawing: Sendable {
    func withdrawPending(sessionId: String, clientMessageIds: [String]) async throws -> WithdrawPendingResponse
}

extension PaiApiClient: OutboxWithdrawing {}

/// What one Undo send did, for a caller that wants to say so.
public struct UndoSendSummary: Equatable, Sendable {
    /// Messages whose text went back into the composer.
    public var restored = 0
    /// Messages Claude already has.
    public var delivered = 0
    /// Messages that could not be settled and were left as they were.
    public var undecided = 0
    /// The server could not be asked at all, so every message that may be on it was left alone.
    public var requestFailed = false

    public init(restored: Int = 0, delivered: Int = 0, undecided: Int = 0, requestFailed: Bool = false) {
        self.restored = restored
        self.delivered = delivered
        self.undecided = undecided
        self.requestFailed = requestFailed
    }

    /// The sentence to show, or `nil` when nothing needs saying: the text visibly landed in the
    /// composer. `announceNothing` is the menu entry (an explicit tap deserves an answer); the
    /// per-bubble action passes `false`.
    public func toast(announceNothing: Bool) -> String? {
        if restored > 0 { return nil }
        if requestFailed { return "Could not reach the server to undo — try again" }
        if delivered > 0 { return "Already delivered" }
        if undecided > 0 { return "Could not undo yet — the session has not confirmed it" }
        return announceNothing ? "Nothing to undo" : nil
    }
}

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
    /// Called once an entry actually reaches the server. The app installs
    /// ``installHandover(drafts:sessions:handoff:)`` here; this stays a plain closure so a test can
    /// observe the moment without one.
    public var onSent: (@MainActor (OutboxEntry) -> Void)?
    /// Called when the server REFUSED an entry because it was pulled back (Escape-undo, here or
    /// on another device) before it could be delivered — the entry is already gone from
    /// ``entries``. The `Bool` is whether the server's own draft already holds the text; when it
    /// does not, the handler owns putting the text back.
    public var onRefused: (@MainActor (OutboxEntry, Bool) -> Void)?
    /// Entries an ``undoSend`` has asked the server about and not heard back on — the worker
    /// leaves them alone meanwhile, so no further request carrying one is issued while its fate
    /// is being decided.
    private var withdrawing: Set<String> = []

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

    /// Everything that must happen the instant an entry reaches the server, in one place.
    ///
    /// A send's whole outcome lives here because there is nowhere else for it to live: the screen
    /// that composed it does not wait for the network, so by the time the server has the row
    /// there is no awaited call to return anything to. The draft version the send consumed is
    /// recorded, a create's row goes into the list and its id is handed to the new-session
    /// screen, and only then is the entry retired.
    ///
    /// Retired immediately rather than left `.sent`: the transcript's own confirmed row — or
    /// ``TranscriptStore``'s server-reported pending list, for a send from another device — takes
    /// over showing it from here, and a `.sent` entry left behind is a bubble with nothing to do.
    /// 🚨 **That retirement is why everything a landed send has to produce belongs in this
    /// closure and nowhere else.** A `.sent` entry is never observable from outside it: anything
    /// polling ``entries`` for one finds an empty queue instead, which reads as a send that was
    /// removed rather than one that succeeded. A create's id reaching nobody that way is a
    /// session sitting in the list with the reader still on the screen that made it.
    public func installHandover(drafts: DraftStore, sessions: SessionListStore, handoff: NewSessionHandoff) {
        onSent = { [weak self, weak drafts, weak sessions] entry in
            drafts?.recordVersionAfterSend(key: entry.draftKey, version: entry.result?.draftVersion)
            if let created = sessions?.adoptCreatedSession(entry) {
                handoff.created(sessionID: created)
            }
            self?.discard(id: entry.id)
        }
        onRefused = { [weak drafts] entry, textInDraft in
            guard !textInDraft, let drafts else { return }
            Self.putBack([entry.text], into: drafts, key: entry.draftKey)
        }
    }

    /// Writes pulled-back texts into a composer: newline-joined, ahead of whatever is already
    /// typed with a blank line between.
    public static func putBack(_ texts: [String], into drafts: DraftStore, key: String) {
        let pulled = texts.filter { !$0.isEmpty }.joined(separator: "\n")
        guard !pulled.isEmpty else { return }
        let current = drafts.draft(for: key).text
        drafts.setDraftText(key: key, text: current.isEmpty ? pulled : "\(pulled)\n\n\(current)")
    }

    /// Whether a request carrying this entry may have reached the server: one is in the air
    /// (`.sending`, which a restart turns back into `.queued` and sends again at once), or an
    /// earlier one failed without an answer (`attempts`). The only entries that cannot are those
    /// no request was ever issued for.
    private static func mayHaveLeft(_ entry: OutboxEntry) -> Bool {
        entry.state == .sending || entry.attempts > 0
    }

    /// Undo send. Pulls every still-unsent message for one session back into its composer,
    /// oldest first, and reports what it did.
    ///
    /// What a message is allowed to be afterwards is exactly one of: back in the composer, or
    /// delivered — never both, never neither. So an entry is treated as purely local ONLY when no
    /// request carrying it was ever issued; one whose request is in the air, timed out, or was
    /// interrupted by a restart may already be on the server, and is named to the server by its
    /// id instead. The server withdraws it if it arrived, or leaves a tombstone so it is refused
    /// when it does; its answer decides, and the entry is kept untouched when the request itself
    /// fails (so the same action can simply be tried again). Texts return in the order: rows the
    /// server withdrew, then entries the server tombstoned, then entries that never left.
    @discardableResult
    public func undoSend(sessionId: String, drafts: DraftStore) async -> UndoSendSummary {
        let eligible = entries(for: sessionId)
            .filter { $0.state == .queued || $0.state == .sending || $0.state == .failed }
            .sorted { $0.createdAt < $1.createdAt }
        let neverLeft = eligible.filter { !Self.mayHaveLeft($0) }
        let mayBeOnServer = eligible.filter(Self.mayHaveLeft)

        // Dropped before anything is awaited, so no worker can issue a request for one of these
        // in between.
        let neverLeftTexts = neverLeft.map(\.text)
        for entry in neverLeft { discard(id: entry.id) }
        for entry in mayBeOnServer { withdrawing.insert(entry.id) }

        var summary = UndoSendSummary()
        var response: WithdrawPendingResponse?
        do {
            guard let withdrawer = api as? any OutboxWithdrawing else { throw PaiError.transport("cannot withdraw") }
            response = try await withdrawer.withdrawPending(
                sessionId: sessionId, clientMessageIds: mayBeOnServer.map(\.id))
        } catch {
            // Nothing is known about those entries, so none of them is touched.
            summary.requestFailed = !mayBeOnServer.isEmpty
        }
        for entry in mayBeOnServer { withdrawing.remove(entry.id) }

        let serverRows = response?.withdrawn ?? []
        let restoredIds = Set(response?.withdrawnClientIds ?? [])
        let deliveredIds = Set(response?.deliveredClientIds ?? [])
        let rowIds = Set(serverRows.compactMap(\.clientMessageId))
        // Entries still here: a request that was in the air may have resolved meanwhile and
        // restored its own text (see ``attemptSend(at:)``).
        let present = Set(entries.map(\.id))
        let tombstoned = mayBeOnServer.filter {
            restoredIds.contains($0.id) && !rowIds.contains($0.id) && present.contains($0.id)
        }
        let deliveredHere = mayBeOnServer.filter { deliveredIds.contains($0.id) }
        for entry in mayBeOnServer where restoredIds.contains(entry.id) || deliveredIds.contains(entry.id) {
            discard(id: entry.id)
        }

        let pulledBack = (serverRows.map(\.text) + tombstoned.map(\.text) + neverLeftTexts).filter { !$0.isEmpty }
        Self.putBack(pulledBack, into: drafts, key: sessionId)

        summary.restored = pulledBack.count
        summary.delivered = max(deliveredHere.count, response?.alreadyDelivered.count ?? 0)
        summary.undecided = response?.unresolved.count ?? 0
        // Entries left in place (request failed, or undecided) still owe their delivery.
        ensureWorker(for: OutboxTarget.session(sessionId: sessionId).workerKey)
        return summary
    }

    /// The entries to show for a target, oldest first — a composer's own pending-bubble list.
    public func entries(for sessionId: String) -> [OutboxEntry] {
        entries.filter { $0.target.sessionId == sessionId }
    }

    /// The sends composed before the session they will create exists — the new-session screen's
    /// own pending-bubble list, and the only place they are visible at all.
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
            guard
                let index = entries.firstIndex(where: {
                    $0.target.workerKey == key && $0.state == .queued && !withdrawing.contains($0.id)
                })
            else {
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
            if response.withdrawn {
                // The server refused it: it was pulled back before it could be delivered. If an
                // undo already took the entry there is nothing left to do (the guard above);
                // otherwise this one is the only thing that knows to put the text back.
                let refused = entries[current]
                discard(id: refused.id)
                onRefused?(refused, response.textInDraft)
                return
            }
            entries[current].state = .sent
            entries[current].result = OutboxResult(
                sessionId: response.sessionId, messageId: response.messageId, draftVersion: response.draftVersion)
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
