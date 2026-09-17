import Foundation
import Observation

/// Composer text kept on the server so every one of Freddy's clients shows the same half-written
/// message. Swift port of `pai-cloud/web/src/stores/drafts.ts`.
///
/// **What this deliberately does not hold:** staged photo/file attachments. The web keeps those
/// client-local and never syncs them (`docs/ARCHITECTURE.md` "Drafts": "Attachments are not
/// synced: they stay in the client that picked them"), and how iOS collects them — a
/// `PHPickerViewController`/`UIDocumentPickerViewController` result — is app-target state, not
/// this package's job to model; see the composer block's own scope note.
///
/// **Local persistence across a relaunch is deliberately not built in.** The web mirrors to
/// `localStorage` as a convenience only — its own comment: "the server copy is still
/// authoritative" — and swallows a write failure outright. Correctness here never depends on it,
/// so it did not seem worth the risk of a Linux-vs-Apple `UserDefaults` behaviour gap for a pure
/// durability nicety; if it is wanted, it is a thin wrapper the app target can add outside this
/// type without touching the reconciliation logic below.
///
/// `@MainActor`, matching `TranscriptStore` — every realistic caller is UI-driven.
@MainActor
@Observable
public final class DraftStore {

    /// Long enough that ordinary typing produces one request; short enough that switching device
    /// right after typing finds the draft already there.
    public static let flushDebounceSeconds: TimeInterval = 0.7
    public static let clearedGraceSeconds: TimeInterval = 5

    public internal(set) var drafts: [String: DraftEntry] = [:]
    /// One-shot signal: bumped whenever a New Session launch choice is made by tapping something
    /// that would otherwise steal focus from the composer, so a view can reclaim it. Never reset
    /// — a consumer reacts to the bump itself, not to a boolean.
    public internal(set) var composerFocusNonce = 0

    private let api: any DraftsFetching
    private let clock: WallClock
    private let scheduler: DraftScheduler

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
        api: some DraftsFetching, clock: WallClock = SystemWallClock(), scheduler: DraftScheduler = RealDraftScheduler()
    ) {
        self.api = api
        self.clock = clock
        self.scheduler = scheduler
    }

    /// The draft for a key, or an empty one — callers never handle a missing entry themselves.
    public func draft(for key: String) -> DraftEntry {
        drafts[key] ?? .empty
    }

    public func requestComposerFocus() {
        composerFocusNonce += 1
    }

    // MARK: - Editing

    public func setDraftText(key: String, text: String) {
        var entry = draft(for: key)
        entry.text = text
        drafts[key] = entry
        scheduleFlush(key)
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

        // A discard must not overtake a write already in flight for the same key, or the delete
        // could land first and the write resurrect an entry that was just cleared.
        let priorFlush = inFlightFlush[key]
        let api = self.api
        Task {
            _ = await priorFlush?.value
            _ = try? await api.deleteDraft(key: key)
        }
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
        guard let entry = drafts[key] else { return }

        flushSequence[key, default: 0] += 1
        let mySequence = flushSequence[key]!

        let write = Task { [weak self, api] in
            guard let self else { return }
            do {
                let result = try await api.putDraft(
                    key: key, text: entry.text, sessionType: entry.sessionType, workingDir: entry.workingDir,
                    model: entry.model, thinking: entry.thinking
                )
                let updatedAt: String? = {
                    switch result {
                    case .saved(let draft): return draft.updatedAt
                    case .deleted: return nil
                    }
                }()
                guard var current = self.drafts[key] else { return }
                current.remoteUpdatedAt = updatedAt
                self.drafts[key] = current
                self.retryAttempt[key] = nil
            } catch {
                // Keep the local copy and retry — scheduled into `pendingFlush`, the same slot a
                // fresh edit's own debounce uses, so `syncFromServer` treats a write still
                // waiting to retry exactly like one still waiting to happen for the first time:
                // strictly newer than anything the server can report, never overwritten by an
                // older row landing in between.
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
            // than the row — adopting it would put back text the device already replaced.
            if inFlightFlush[row.key] != nil || localRevision[row.key] != revisionsAtRequest[row.key] { continue }
            // A key just discarded, whose delete this response may predate.
            if let clearedTime = clearedAt[row.key],
                clock.now().timeIntervalSince(clearedTime) < Self.clearedGraceSeconds
            {
                continue
            }
            if let local = drafts[row.key], local.remoteUpdatedAt == row.updatedAt { continue }
            drafts[row.key] = DraftEntry(
                text: row.text, sessionType: row.sessionType, workingDir: row.workingDir, model: row.model,
                thinking: row.thinking, remoteUpdatedAt: row.updatedAt
            )
        }

        for key in Array(drafts.keys) {
            guard !seen.contains(key), let local = drafts[key], local.remoteUpdatedAt != nil, pendingFlush[key] == nil,
                inFlightFlush[key] == nil, localRevision[key] == revisionsAtRequest[key]
            else {
                continue
            }
            // Reconciled with the server once and gone from it now: another client sent or
            // discarded it.
            drafts[key] = nil
        }
    }
}
