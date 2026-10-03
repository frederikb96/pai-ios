import Foundation
import Observation

/// Composer text kept on the server so every one of Freddy's clients shows the same half-written
/// message. Swift port of `pai-cloud/web/src/stores/drafts.ts`'s version-ordered rewrite.
///
/// **The device being typed on owns the text.** A composer's field reads this store's own local
/// copy only; nothing coming from the network may replace a value the user is looking at unless
/// the local copy is clean *and* the server proves the change is strictly newer
/// (``syncFromServer()``'s `version` comparison). Adopting on mere inequality — the previous
/// design — is the bug this rewrite exists to close: a poll response produced *before* a flush
/// this device already sent, but delivered *after* that flush's own answer, used to pass every
/// staleness guard and replace the field with older text. `version` makes that ordering explicit
/// instead of inferred from an opaque, unordered `updated_at` token.
///
/// **A relaunch restores `drafts` from `localPersistence`, mirroring the web's own
/// `localStorage`/`loadStored()` contract.** Restoring is never a local claim on anything it
/// names — it populates `drafts` alone, with no pending write and no `knownVersion` bump — so the
/// very first ``syncFromServer()`` afterwards adopts the server's row whenever its version is
/// newer and drops this one's claim on that key if the server has since moved past it, exactly as
/// any other unclaimed key would be treated.
///
/// `@MainActor`, matching `TranscriptStore` — every realistic caller is UI-driven.
@MainActor
@Observable
public final class DraftStore {

    /// Long enough that ordinary typing produces one request; short enough that switching device
    /// right after typing finds the draft already there. Freddy's own concession: cross-device
    /// text sync is "pick up where I left off", not real-time mirroring — seconds of lag is fine.
    public static let flushDebounceSeconds: TimeInterval = 2

    public internal(set) var drafts: [String: DraftEntry] = [:] {
        didSet { localPersistence?.setValue(drafts, forKey: Keys.localDrafts) }
    }
    /// One-shot signal: bumped whenever a New Session launch choice is made by tapping something
    /// that would otherwise steal focus from the composer, so a view can reclaim it. Never reset
    /// — a consumer reacts to the bump itself, not to a boolean.
    public internal(set) var composerFocusNonce = 0

    private enum Keys {
        static let localDrafts = "drafts.local"
        static let deviceId = "drafts.deviceId"
    }

    private let api: any DraftsFetching
    private let clock: WallClock
    private let scheduler: DraftScheduler
    /// `nil` in every test and in any caller that does not care — the app wires its own shared
    /// log in. Logs only the events that decide whether text survives (a clear, a flush, a sync
    /// dropping a key), never every edit: a live take writes this store many times a second, and a
    /// line per keystroke would flood the very log meant to make a loss like this one legible.
    private let diagnosticsLog: VoiceDiagnosticsLog?
    /// `nil` in every test that does not care, exactly like `diagnosticsLog` — the app wires its
    /// own `UserDefaults` in. See ``drafts`` for what is restored from it and why.
    private let localPersistence: SettingsKeyValueStore?
    /// This device's own id — a uuid minted once and persisted, sent with every write purely for
    /// diagnostics and the "recording on <device>" hint. Never consulted for an ownership
    /// decision, here or server-side.
    public let deviceId: String

    /// The debounce timer for a key's next flush — also where a failed write's retry backoff
    /// lives, so a fresh edit's own debounce naturally cancels and replaces a pending retry rather
    /// than the two racing each other.
    private var pendingDebounce: [String: Task<Void, Never>] = [:]
    /// The network call presently in flight for a key — a write (`.write`) or an explicit discard
    /// (`.delete`). At most one at a time, by construction: everything that wants to touch the
    /// server for a key goes through ``requestOp(_:_:)``, which either starts this or queues.
    private var currentOp: [String: Task<Void, Never>] = [:]
    /// What to do again the moment `currentOp[key]` finishes — coalescing, never fan-out. A write
    /// requested while one is already in flight for the same key sets this rather than starting a
    /// second request; the in-flight request's own completion is what fires the queued one, with
    /// whatever text is current *then*, not whatever it was when it was queued. At most one
    /// pending op per key: the most recently requested op wins, matching "last writer wins" — an
    /// edit queued behind an in-flight delete supersedes the delete's own re-queue and vice versa.
    private var queuedOp: [String: PendingOp] = [:]
    /// Bumped on every local change to a key. A poll whose request left before a change carries
    /// that key's older server copy, however its response is ordered against the write.
    private var localRevision: [String: Int] = [:]
    /// Consecutive failed flush attempts per key — what `scheduleRetry` doubles the wait on, and
    /// what a fresh edit (`scheduleFlush`) resets, so a retry backoff never survives past the
    /// edit it was retrying.
    private var retryAttempt: [String: Int] = [:]

    private enum PendingOp: Equatable { case write, delete }

    public init(
        api: some DraftsFetching, clock: WallClock = SystemWallClock(),
        scheduler: DraftScheduler = RealDraftScheduler(),
        diagnosticsLog: VoiceDiagnosticsLog? = nil,
        localPersistence: SettingsKeyValueStore? = nil
    ) {
        self.api = api
        self.clock = clock
        self.scheduler = scheduler
        self.diagnosticsLog = diagnosticsLog
        self.localPersistence = localPersistence
        drafts = localPersistence?.value(forKey: Keys.localDrafts) ?? [:]
        if let existing: String = localPersistence?.value(forKey: Keys.deviceId) {
            deviceId = existing
        } else {
            let minted = UUID().uuidString
            deviceId = minted
            localPersistence?.setValue(minted, forKey: Keys.deviceId)
        }
    }

    /// The draft for a key, or an empty one — callers never handle a missing entry themselves.
    public func draft(for key: String) -> DraftEntry {
        drafts[key] ?? .empty
    }

    public func requestComposerFocus() {
        composerFocusNonce += 1
    }

    // MARK: - Editing

    /// Writes the human's own text — and, during a live dictation take, the machine's assembled
    /// text too, through this exact same setter: there is only one owner of the field, whichever
    /// is currently writing to it, never two competing representations.
    public func setDraftText(key: String, text: String) {
        var entry = draft(for: key)
        entry.text = text
        drafts[key] = entry
        scheduleFlush(key)
    }

    /// The composer's "Restore earlier version" action — writes `previousText` back as the
    /// current text through the ordinary setter, exactly as if it had been typed. The plus menu
    /// only ever offers this when `previousText` is non-empty and differs from `text`; this method
    /// itself stays defensive about that so a stale menu tap can never write an empty string over
    /// something real.
    public func restorePreviousText(key: String) {
        guard let previous = draft(for: key).previousText, !previous.isEmpty else { return }
        setDraftText(key: key, text: previous)
    }

    /// A discard is fire-and-forget, so its answer can land after a write this device made since —
    /// in which case it describes an older state of the row and must not move the restore target
    /// backwards onto the discarded text. `version == nil` means there was no row at all to
    /// discard: nothing was destroyed and there is no version to record.
    private func applyDiscardResult(key: String, result: PaiDraftDeleteResult) {
        guard let version = result.version else { return }
        guard var current = drafts[key] else { return }
        if (current.knownVersion ?? -1) > version { return }
        current.knownVersion = version
        current.previousText = result.previousText
        drafts[key] = current
    }

    /// Launch choices for the next session, held in the `new` draft only.
    /// Any type but Custom drops a previously chosen directory, the same coupling as
    /// `selectWorkingDir` from the other side — or a relaunch restores the directory and with it
    /// the custom session the type pill said it was not.
    public func selectSessionType(_ id: String?) {
        var entry = draft(for: DraftKey.newSession)
        entry.sessionType = id
        if id != "custom" { entry.workingDir = nil }
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession)
    }

    /// A chosen directory is what makes a session custom, so the two always move together: a
    /// real path stamps `sessionType = "custom"`, and clearing the path clears the type with it.
    public func selectWorkingDir(_ path: String?) {
        var entry = draft(for: DraftKey.newSession)
        entry.workingDir = path
        entry.sessionType = path != nil ? "custom" : nil
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession)
    }

    public func selectModel(_ id: String?) {
        var entry = draft(for: DraftKey.newSession)
        entry.model = id
        // The set of thinking levels a model accepts is a property of that model
        // (`GET /api/session-models`), so a level chosen for the previous one is not necessarily
        // valid for this one — clear it rather than risk sending a combination the launch would
        // reject.
        entry.thinking = nil
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession)
    }

    public func selectThinking(_ id: String?) {
        var entry = draft(for: DraftKey.newSession)
        entry.thinking = id
        drafts[DraftKey.newSession] = entry
        scheduleFlush(DraftKey.newSession)
    }

    // MARK: - Attachments

    /// Uploads a staged file onto this draft immediately — not debounced like `setDraftText`,
    /// since there is nothing to coalesce: each attachment is its own request, made once, the
    /// moment it is picked. `nil` on failure; the caller (`StagedAttachmentStore`) is what keeps
    /// the bytes around to fall back to sending inline at message-send time.
    public func addAttachment(key: String, file: PaiFileUpload) async -> DraftAttachment? {
        guard let attachment = try? await api.addDraftAttachment(key: key, file: file) else { return nil }
        var entry = draft(for: key)
        entry.attachments.append(attachment)
        drafts[key] = entry
        return attachment
    }

    /// Removes an attachment from this draft — the local copy first, so the chip disappears at
    /// once rather than waiting on `syncFromServer`'s own poll, then the server's.
    public func removeAttachment(key: String, attachmentId: String) async {
        var entry = draft(for: key)
        entry.attachments.removeAll { $0.id == attachmentId }
        drafts[key] = entry
        _ = try? await api.removeDraftAttachment(key: key, attachmentId: attachmentId)
    }

    // MARK: - Clearing

    /// Discards a draft, locally and on the server — implemented server-side as an empty text
    /// plus a version bump plus attachment cleanup; the row itself is never removed. Local state
    /// clears immediately; the network call is serialized against whatever else is already
    /// touching this key exactly like any other op (``requestOp(_:_:)``), so a write already in
    /// flight for older text cannot land after this discard and put it back.
    ///
    /// **The entry itself is kept, only emptied — never set to `nil`.** Dropping it entirely would
    /// drop `knownVersion` with it, and a poll response that predates the discard (still reporting
    /// the pre-discard row) would then read as newer than nothing and put the discarded text
    /// straight back. `performOp`'s own `.delete` case updates `knownVersion` again once the
    /// discard's own response names the version it actually produced, closing the gap for the
    /// interval before that response lands too.
    ///
    /// **When a caller should call this:** after its own send request resolves successfully —
    /// never optimistically, and never gated on the transcript confirming the send. A failed send
    /// must leave the draft in place so nothing typed is lost, which is why this is a call the
    /// composer makes itself rather than something triggered by send-tracking here.
    public func clearDraft(key: String) {
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = nil
        var entry = draft(for: key)
        entry.text = ""
        entry.attachments = []
        drafts[key] = entry
        localRevision[key, default: 0] += 1
        retryAttempt[key] = nil
        diagnosticsLog?.log(.info, .drafts, "clear key=\(key)")
        Task { await self.requestOp(key, .delete) }
    }

    // MARK: - Flush (debounced write)

    private func scheduleFlush(_ key: String) {
        localRevision[key, default: 0] += 1
        retryAttempt[key] = nil
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: Self.flushDebounceSeconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingDebounce[key] = nil
            await self.requestOp(key, .write)
        }
    }

    /// How long a failed flush waits before retrying, doubling per consecutive failure up to a
    /// cap — frequent enough that one dropped request heals within a few seconds, capped low
    /// enough that a genuinely offline device is not hammering the server for the rest of a call.
    public static let retryBaseSeconds: TimeInterval = 2
    public static let retryMaxSeconds: TimeInterval = 30

    /// Writes the current value of a draft to the server right now, waiting for it (and any op
    /// already in flight ahead of it) to fully land. Public because the composer must call this
    /// directly — not through the debounce — when it is about to disappear, so leaving a session
    /// cannot strand an edit inside the debounce window.
    public func flush(key: String) async {
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = nil
        guard drafts[key] != nil else { return }
        await requestOp(key, .write)
    }

    /// The one place anything asks the server to change a key — a write or a discard. At most one
    /// request in flight per key: a request arriving while one is already running is coalesced
    /// into ``queuedOp``, never fired as a second, concurrent request. This is the fix for the fix
    /// the web's own investigation named: the previous shape awaited the in-flight request and
    /// *then* started its own, which fans every debounce that expired while a slow write was on
    /// the wire out into its own follow-up PUT — up to one per keystroke. Coalescing collapses any
    /// number of those into exactly one further write, carrying whatever text is current the
    /// moment the in-flight request actually finishes.
    private func requestOp(_ key: String, _ op: PendingOp) async {
        if currentOp[key] != nil {
            queuedOp[key] = op
            await currentOp[key]?.value
            return
        }
        await performOp(key, op)
    }

    /// Runs one op to completion, then — if something was requested while it ran — runs that one
    /// too, awaited from inside this same task so a caller of ``requestOp(_:_:)`` that finds
    /// `currentOp` already set and simply awaits it is guaranteed the *whole* coalesced chain has
    /// drained by the time that await returns, not just the request it happened to observe.
    private func performOp(_ key: String, _ op: PendingOp) async {
        let log = diagnosticsLog
        let task = Task { [weak self] in
            guard let self else { return }
            switch op {
            case .write:
                await self.performWrite(key: key, log: log)
            case .delete:
                if let result = try? await self.api.deleteDraft(key: key) {
                    self.applyDiscardResult(key: key, result: result)
                    log?.log(.info, .drafts, "delete key=\(key) version=\(String(describing: result.version)) done")
                }
            }
            self.currentOp[key] = nil
            if let next = self.queuedOp[key] {
                self.queuedOp[key] = nil
                await self.performOp(key, next)
            }
        }
        currentOp[key] = task
        await task.value
    }

    private func performWrite(key: String, log: VoiceDiagnosticsLog?) async {
        guard let entry = drafts[key] else { return }
        do {
            let result = try await api.putDraft(
                key: key, text: entry.text, deviceId: deviceId, sessionType: entry.sessionType,
                workingDir: entry.workingDir, model: entry.model, thinking: entry.thinking
            )
            guard var current = drafts[key] else { return }
            current.knownVersion = result.version
            current.previousText = result.previousText
            drafts[key] = current
            retryAttempt[key] = nil
            log?.log(.info, .drafts, "flush key=\(key) chars=\(entry.text.count) version=\(result.version) done")
        } catch {
            // Keep the local copy and retry — scheduled into `pendingDebounce`, the same slot a
            // fresh edit's own debounce uses, so `syncFromServer` treats a write still waiting to
            // retry exactly like one still waiting to happen for the first time: strictly newer
            // than anything the server can report, never overwritten by an older row landing in
            // between. A queued coalesced follow-up (if any) is dropped in favour of the retry,
            // which will pick up whatever text is current when it fires anyway.
            queuedOp[key] = nil
            log?.log(.warning, .drafts, "flush key=\(key) failed, retrying: \(error)")
            scheduleRetry(key)
        }
    }

    private func scheduleRetry(_ key: String) {
        let attempt = (retryAttempt[key] ?? 0) + 1
        retryAttempt[key] = attempt
        let delay = min(Self.retryBaseSeconds * pow(2, Double(attempt - 1)), Self.retryMaxSeconds)
        pendingDebounce[key]?.cancel()
        pendingDebounce[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingDebounce[key] = nil
            await self.requestOp(key, .write)
        }
    }

    // MARK: - Reconciling with the server

    /// Adopts every server row this device does not have a fresher local claim on. A key absent
    /// from the response is never touched — the row is never actually gone (a discard writes
    /// empty text, it never deletes), so a poll answering without a key it used to list means
    /// nothing about that key at all, never "delete the local copy".
    public func syncFromServer() async {
        let revisionsAtRequest = localRevision
        let remote: [Draft]
        do {
            remote = try await api.getDrafts()
        } catch {
            return
        }

        for row in remote {
            // A key with an unwritten local edit, a write or delete already on the wire, or any
            // local change since this request left, is newer than anything this response can
            // report — adopting it would put back text the device already replaced. Comparing
            // `localRevision` against the snapshot taken before the request left is what catches
            // "changed while the request was in flight" even once the write that caused it has
            // itself already finished.
            let isClean =
                pendingDebounce[row.key] == nil && currentOp[row.key] == nil
                && localRevision[row.key] == revisionsAtRequest[row.key]
            var entry = drafts[row.key] ?? .empty
            var changed = false
            // `row.version <= knownVersion` is ignored regardless of content — this is the rule
            // that replaces comparing `updated_at` for inequality, and it is what makes a response
            // that predates this device's own flush harmless however it is ordered on arrival.
            if isClean, row.version > (entry.knownVersion ?? -1) {
                entry.text = row.text
                entry.sessionType = row.sessionType
                entry.workingDir = row.workingDir
                entry.model = row.model
                entry.thinking = row.thinking
                entry.knownVersion = row.version
                changed = true
            }
            // Attachments are a separate resource with set semantics, adopted always and
            // independently of the text-ordering rule above — they already have the right model
            // (tombstones on removal), and another device's just-added file should appear even
            // while this device's own text edit is still in flight.
            if entry.attachments != row.attachments {
                entry.attachments = row.attachments
                changed = true
            }
            // `previousText` is informational, like attachments — adopted whenever the row is not
            // older than what this device knows, independent of whether the text itself is dirty.
            // A dirty entry's `knownVersion` is exactly "the version this device last reconciled
            // with", so a row from another device sitting ahead of that is still newer information
            // about what to offer as "Restore earlier version", even while this device's own edit
            // is what is actually on screen.
            if row.version >= (entry.knownVersion ?? -1), entry.previousText != row.previousText {
                entry.previousText = row.previousText
                changed = true
            }
            if changed {
                drafts[row.key] = entry
            }
        }
    }

    /// After a successful send has cleared this draft server-side, records the version that clear
    /// produced — so this device's own next poll is a no-op rather than a wasted round trip. A
    /// pure optimisation: skipping this call changes nothing but the timing of the next
    /// reconciliation, so it is guarded conservatively — only when the key is still exactly the
    /// empty, untouched state the send itself left it in — rather than risk clobbering a fresh
    /// edit typed into the same key before the send's own response arrived.
    public func recordVersionAfterSend(key: String, version: Int?) {
        guard let version else { return }
        guard pendingDebounce[key] == nil, currentOp[key] == nil else { return }
        guard var entry = drafts[key], entry.text.isEmpty else { return }
        entry.knownVersion = version
        drafts[key] = entry
    }
}
