import Foundation
import Observation

/// Composer text kept on the server so every one of Freddy's clients shows the same half-written
/// message. Swift port of `pai-cloud/web/src/stores/drafts.ts`.
///
/// **What this deliberately does not hold:** a staged attachment's own bytes, before they reach
/// the server — how iOS collects them (a `PHPickerViewController`/`UIDocumentPickerViewController`
/// result) is app-target state, not this package's job to model. Once uploaded, though, the
/// attachment itself is exactly as shared as `text` or a dictation region: `addAttachment`/
/// `removeAttachment` write through immediately (no debounce — there is no draft of an
/// attachment, only uploaded or not), and `syncFromServer` folds in whatever another device
/// added, which is the whole point: composing one message from several devices at once.
///
/// **A relaunch restores `drafts` from `localPersistence`, mirroring the web's own
/// `localStorage`/`loadStored()` contract.** Restoring is never a local claim on anything it
/// names — it populates `drafts` alone, with no pending write and no revision bump — so the very
/// first ``syncFromServer()`` afterwards adopts the server's row whenever it differs and drops
/// this one if the server no longer has the key, exactly as any other unclaimed key would be
/// treated. Doing it any other way (as a pending write, say) would let a stale draft from before
/// the relaunch overwrite something fresher already on the server, which is the regression this
/// store exists to prevent. This is the one place a version of Freddy's text exists nowhere but
/// here — nowhere else in this file needs to survive a relaunch, since every other write is
/// either already on the server or about to be retried onto it.
///
/// `@MainActor`, matching `TranscriptStore` — every realistic caller is UI-driven.
@MainActor
@Observable
public final class DraftStore {

    /// Long enough that ordinary typing produces one request; short enough that switching device
    /// right after typing finds the draft already there.
    public static let flushDebounceSeconds: TimeInterval = 0.7
    public static let clearedGraceSeconds: TimeInterval = 5

    public internal(set) var drafts: [String: DraftEntry] = [:] {
        didSet { localPersistence?.setValue(drafts, forKey: Keys.localDrafts) }
    }
    /// One-shot signal: bumped whenever a New Session launch choice is made by tapping something
    /// that would otherwise steal focus from the composer, so a view can reclaim it. Never reset
    /// — a consumer reacts to the bump itself, not to a boolean.
    public internal(set) var composerFocusNonce = 0

    private enum Keys {
        static let localDrafts = "drafts.local"
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

    /// Keys with a local edit not yet written to the server — including one waiting out a retry
    /// backoff after a failed write, which schedules into this same slot (`scheduleRetry`).
    private var pendingFlush: [String: Task<Void, Never>] = [:]
    /// The currently in-flight write per key, so a discard can wait for it before undoing it.
    private var inFlightFlush: [String: Task<Void, Never>] = [:]
    /// Guards `inFlightFlush`'s cleanup: a `Task` has no identity comparison in Swift, so a
    /// monotonic counter per key stands in for "is the flush that just finished still the one
    /// `inFlightFlush` should forget" — a newer flush started while it was in the air must not
    /// have its own in-flight marker erased from under it.
    private var flushSequence: [String: Int] = [:]
    /// The currently in-flight delete per key — what `flush()` waits out before putting anything
    /// back. A delete removes a key from the server, not the row `clearDraft` was reacting to, so
    /// a fresh edit's own write landing on the server *before* a slow delete arrives there would
    /// have the delete remove that newer text right back out from under it, by name, the moment it
    /// finally lands — waiting here is what keeps the two from ever being in flight together.
    private var inFlightDelete: [String: Task<Void, Never>] = [:]
    /// `inFlightDelete`'s own cleanup guard, the same shape as `flushSequence`.
    private var deleteSequence: [String: Int] = [:]
    /// The currently in-flight flatten per key — what `flush()` waits out before writing `text`.
    ///
    /// A flatten folds every open region INTO the server's `text`, so it and a write of `text`
    /// are two edits to one field, and the server applies whichever arrives second. The write is
    /// debounced and the flatten is not, so without this the order is whatever the network
    /// chooses. Flatten landing last puts every dictated word straight back: the empty text
    /// arrives, then the fold rewrites the field from the regions, which reads as a deletion the
    /// composer refused. Waiting here makes the pair ordered — the same reasoning, and the same
    /// shape, as `inFlightDelete` above.
    private var inFlightFlatten: [String: Task<Void, Never>] = [:]
    /// Recently discarded keys, so a sync already in flight cannot resurrect one. Pruned in
    /// `syncFromServer` once an entry's grace window has passed — left unpruned this is the one
    /// unbounded map in an otherwise careful type, one `Date` held for the process lifetime per
    /// discard. Not `private`, so a test can observe the prune directly.
    var clearedAt: [String: Date] = [:]
    /// Bumped on every local change to a key. A poll whose request left before a change carries
    /// that key's older server copy, however its response is ordered against the write.
    private var localRevision: [String: Int] = [:]
    /// Consecutive failed flush attempts per key — what `scheduleRetry` doubles the wait on, and
    /// what a fresh edit (`scheduleFlush`) resets, so a retry backoff never survives past the
    /// edit it was retrying.
    private var retryAttempt: [String: Int] = [:]

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
    }

    /// The draft for a key, or an empty one — callers never handle a missing entry themselves.
    public func draft(for key: String) -> DraftEntry {
        drafts[key] ?? .empty
    }

    public func requestComposerFocus() {
        composerFocusNonce += 1
    }

    // MARK: - Editing

    /// Writes the human's own text. **A machine never writes here** — a live dictation take
    /// writes its own region instead (`writeDictationRegion(key:takeId:text:state:seq:)`), which
    /// is what a keystroke landing here mid-take never collides with.
    ///
    /// Editing while a region is still open is a write to machine-owned text otherwise — see
    /// ``DraftEntry/displayText`` — so this flattens first: the open regions fold into `text`
    /// server-side (fire-and-forget; the local fold below is what makes the field editable at
    /// once rather than waiting on the round trip) and this device stops tracking them as
    /// separate regions from here on. A caller passing the CURRENT `displayText` back with one
    /// character changed — exactly what a `TextEditor` binding does — is what makes the local
    /// fold correct: `text` becomes the flattened whole, so this same edit is never applied twice.
    public func setDraftText(key: String, text: String) {
        var entry = draft(for: key)
        if entry.hasOpenRegions {
            flattenOpenRegions(key: key, entry: entry)
            entry.regions = []
        }
        entry.text = text
        drafts[key] = entry
        scheduleFlush(key)
    }

    /// Starts the server-side flatten and records it, so the write that follows this same edit
    /// cannot overtake it — see `inFlightFlatten`. This device's own fold above is what makes the
    /// field usable immediately; the round trip needs to happen at all so another device reading
    /// this draft afterward sees the same flattened `text` rather than a region this device has
    /// stopped believing exists.
    private func flattenOpenRegions(key: String, entry: DraftEntry) {
        let openTakeIds = entry.regions.filter { $0.state == "open" }.map(\.takeId)
        guard !openTakeIds.isEmpty else { return }
        let api = self.api
        let baseUpdatedAt = entry.remoteUpdatedAt
        let flatten = Task { [weak self] in
            _ = try? await api.flattenDraft(key: key, takeIds: openTakeIds, baseUpdatedAt: baseUpdatedAt)
            self?.inFlightFlatten[key] = nil
        }
        inFlightFlatten[key] = flatten
    }

    /// Launch choices for the next session, held in the `new` draft only.
    public func selectSessionType(_ id: String?) {
        var entry = draft(for: DraftKey.newSession)
        entry.sessionType = id
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

    /// Discards a draft, locally and on the server.
    ///
    /// **When a caller should call this:** after its own send request resolves successfully —
    /// never optimistically, and never gated on the transcript confirming the send (`outbox_id`
    /// reconciliation is a separate concern; see `TranscriptStore`). A failed send must leave the
    /// draft in place so nothing typed is lost, which is why this is a call the composer makes
    /// itself rather than something triggered by send-tracking here.
    public func clearDraft(key: String) {
        pendingFlush[key]?.cancel()
        pendingFlush[key] = nil
        drafts[key] = nil
        clearedAt[key] = clock.now()
        localRevision[key, default: 0] += 1
        diagnosticsLog?.log(.info, .drafts, "clear key=\(key)")

        deleteSequence[key, default: 0] += 1
        let mySequence = deleteSequence[key]!

        // A discard must not overtake a write already in flight for the same key, or the delete
        // could land first and the write resurrect an entry that was just cleared.
        let priorFlush = inFlightFlush[key]
        let api = self.api
        let log = diagnosticsLog
        let deleteTask = Task { [weak self] in
            _ = await priorFlush?.value
            _ = try? await api.deleteDraft(key: key)
            log?.log(.info, .drafts, "delete key=\(key) done")
            // Only forget the marker if no newer delete has started since — see `deleteSequence`'s
            // doc comment. `flush()` is what actually reads `inFlightDelete`, and it is a fresh
            // edit that starts a newer delete, so this mirrors `flush()`'s own cleanup exactly.
            guard let self, self.deleteSequence[key] == mySequence else { return }
            self.inFlightDelete[key] = nil
        }
        inFlightDelete[key] = deleteTask
    }

    // MARK: - Flush (debounced write)

    private func scheduleFlush(_ key: String) {
        localRevision[key, default: 0] += 1
        retryAttempt[key] = nil
        pendingFlush[key]?.cancel()
        pendingFlush[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: Self.flushDebounceSeconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingFlush[key] = nil
            await self.flush(key: key)
        }
    }

    /// How long a failed flush waits before retrying, doubling per consecutive failure up to a
    /// cap — frequent enough that one dropped request heals within a few seconds, capped low
    /// enough that a genuinely offline device is not hammering the server for the rest of a call.
    /// A previous version left a failed write unretried until the next edit, silently — a draft
    /// nothing else touches for a while (dictated once, then read, never typed into again) never
    /// got the fix it needed.
    public static let retryBaseSeconds: TimeInterval = 2
    public static let retryMaxSeconds: TimeInterval = 30

    /// Writes the current value of a draft to the server. Public because the composer must call
    /// this directly (not through the debounce) when it is about to disappear, so leaving a
    /// session cannot strand an edit inside the debounce window.
    public func flush(key: String) async {
        // A delete already on the wire for this key must land — and actually delete — before
        // this write may start, or a delete an earlier `clearDraft` sent for a now-stale reason
        // can arrive at the server *after* this PUT and remove the very text it just wrote, by
        // key rather than by row. Waiting here means "clear, then edit again before the delete
        // has even reached the server" ends with the server agreeing with the client. Re-reading
        // `drafts[key]` only after this wait is what lets a fresher edit made during it still win.
        if inFlightDelete[key] != nil {
            diagnosticsLog?.log(.info, .drafts, "flush key=\(key) waiting for in-flight delete")
        }
        await inFlightDelete[key]?.value
        // And a flatten started by the very edit this write is carrying: it rewrites `text` from
        // the regions, so landing after this PUT would undo it. See `inFlightFlatten`.
        if inFlightFlatten[key] != nil {
            diagnosticsLog?.log(.info, .drafts, "flush key=\(key) waiting for in-flight flatten")
        }
        await inFlightFlatten[key]?.value
        // And any write already on the wire for this key: reading `entry` only after it settles
        // is what makes THIS write's base version, and its text, the freshest one there is — two
        // writes queued back to back for one key can never race into a spurious conflict, because
        // the second one never even starts building its request until the first has an answer.
        if inFlightFlush[key] != nil {
            diagnosticsLog?.log(.info, .drafts, "flush key=\(key) waiting for in-flight flush")
        }
        await inFlightFlush[key]?.value
        guard let entry = drafts[key] else { return }

        flushSequence[key, default: 0] += 1
        let mySequence = flushSequence[key]!

        let log = diagnosticsLog
        let write = Task { [weak self, api] in
            guard let self else { return }
            do {
                let result = try await api.putDraft(
                    key: key, text: entry.text, sessionType: entry.sessionType, workingDir: entry.workingDir,
                    model: entry.model, thinking: entry.thinking, baseUpdatedAt: entry.remoteUpdatedAt
                )
                switch result {
                case .saved(let draft):
                    guard var current = self.drafts[key] else { return }
                    current.remoteUpdatedAt = draft.updatedAt
                    self.drafts[key] = current
                    self.retryAttempt[key] = nil
                    log?.log(.info, .drafts, "flush key=\(key) chars=\(entry.text.count) done")
                case .deleted:
                    guard var current = self.drafts[key] else { return }
                    current.remoteUpdatedAt = nil
                    self.drafts[key] = current
                    self.retryAttempt[key] = nil
                    log?.log(.info, .drafts, "flush key=\(key) chars=\(entry.text.count) done")
                case .conflict(let draft):
                    // The server's own row is adopted in exactly one place — `syncFromServer`,
                    // and only for a key with no local claim. A conflict here is neither: it may
                    // move the version stamp the next write is based on, never the on-screen
                    // text, which this device's own composer still owns.
                    if let updatedAt = draft.updatedAt {
                        guard var current = self.drafts[key] else { return }
                        current.remoteUpdatedAt = updatedAt
                        self.drafts[key] = current
                        log?.log(.warning, .drafts, "flush key=\(key) conflict, retrying with fresh version")
                        self.scheduleRetry(key)
                    } else {
                        // `updated_at: null` means the row is gone — another device already sent
                        // or discarded this draft. Retrying would resurrect text nobody is
                        // waiting on, so the local copy is dropped rather than rewritten back
                        // onto a row that no longer exists.
                        self.pendingFlush[key]?.cancel()
                        self.pendingFlush[key] = nil
                        self.drafts[key] = nil
                        log?.log(
                            .warning, .drafts, "flush key=\(key) conflict — gone elsewhere, dropping local copy")
                    }
                }
            } catch {
                // Keep the local copy and retry — scheduled into `pendingFlush`, the same slot a
                // fresh edit's own debounce uses, so `syncFromServer` treats a write still
                // waiting to retry exactly like one still waiting to happen for the first time:
                // strictly newer than anything the server can report, never overwritten by an
                // older row landing in between.
                log?.log(.warning, .drafts, "flush key=\(key) failed, retrying: \(error)")
                self.scheduleRetry(key)
            }
        }

        inFlightFlush[key] = write
        await write.value
        // Only forget the marker if no newer flush has started since — see `flushSequence`'s
        // doc comment.
        if flushSequence[key] == mySequence {
            inFlightFlush[key] = nil
        }
    }

    private func scheduleRetry(_ key: String) {
        let attempt = (retryAttempt[key] ?? 0) + 1
        retryAttempt[key] = attempt
        let delay = min(Self.retryBaseSeconds * pow(2, Double(attempt - 1)), Self.retryMaxSeconds)
        pendingFlush[key]?.cancel()
        pendingFlush[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: delay)
            guard !Task.isCancelled, let self else { return }
            self.pendingFlush[key] = nil
            await self.flush(key: key)
        }
    }

    // MARK: - Reconciling with the server

    /// Adopts every server row this device does not have a fresher local claim on, and drops any
    /// local row the server no longer has and this device once agreed with.
    public func syncFromServer() async {
        let revisionsAtRequest = localRevision
        let remote: [Draft]
        do {
            remote = try await api.getDrafts()
        } catch {
            return
        }

        clearedAt = clearedAt.filter { clock.now().timeIntervalSince($0.value) < Self.clearedGraceSeconds }

        var seen = Set<String>()
        for row in remote {
            seen.insert(row.key)
            // A key with an unwritten local edit is newer than anything the server can report —
            // including one waiting to retry after a failed write, which lives in this same slot
            // (`scheduleRetry`) for exactly this reason: a write the server never actually saved
            // must never be overwritten by the older row it failed to replace.
            if pendingFlush[row.key] != nil { continue }
            // A write still in the air, or any local change since this request left, is newer
            // than the row — adopting it would put back text the device already replaced. A
            // delete still in the air counts too: while one is racing, the server's answer for
            // that key is not evidence about anything, and a write waiting behind it sits with
            // neither a pending nor an in-flight flush recorded.
            // A flatten counts for the same reason a delete does: it is about to rewrite `text`
            // from the regions, so the row this response carries describes neither the before
            // nor the after.
            if inFlightFlush[row.key] != nil || inFlightDelete[row.key] != nil
                || inFlightFlatten[row.key] != nil
                || localRevision[row.key] != revisionsAtRequest[row.key]
            {
                continue
            }
            // A key just discarded, whose delete this response may predate.
            if let clearedTime = clearedAt[row.key],
                clock.now().timeIntervalSince(clearedTime) < Self.clearedGraceSeconds
            {
                continue
            }
            // `row.updatedAt` is the DRAFT row's own timestamp — neither a region write nor an
            // attachment upload touches it (both live in their own tables), so a live dictation
            // take's newly committed words, or another device's just-added file, would never be
            // adopted here if this gate only compared that field. Both are compared on their own,
            // since they are what actually changes on every poll while `text` itself does not.
            if let local = drafts[row.key], local.remoteUpdatedAt == row.updatedAt, local.regions == row.regions,
                local.attachments == row.attachments
            {
                continue
            }
            drafts[row.key] = DraftEntry(
                text: row.text, sessionType: row.sessionType, workingDir: row.workingDir, model: row.model,
                thinking: row.thinking, remoteUpdatedAt: row.updatedAt, regions: row.regions,
                attachments: row.attachments
            )
        }

        for key in Array(drafts.keys) {
            guard !seen.contains(key), let local = drafts[key], local.remoteUpdatedAt != nil, pendingFlush[key] == nil,
                inFlightFlush[key] == nil, inFlightDelete[key] == nil,
                localRevision[key] == revisionsAtRequest[key]
            else {
                continue
            }
            // Reconciled with the server once and gone from it now: another client sent or
            // discarded it.
            diagnosticsLog?.log(
                .warning, .drafts, "sync dropped key=\(key) — reconciled once, server no longer lists it")
            drafts[key] = nil
        }
    }
}
