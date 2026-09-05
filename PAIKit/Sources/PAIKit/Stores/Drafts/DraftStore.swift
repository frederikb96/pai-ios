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

    /// Keys with a local edit not yet written to the server.
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
        pendingFlush[key]?.cancel()
        pendingFlush[key] = Task { [weak self, scheduler] in
            try? await scheduler.sleep(seconds: Self.flushDebounceSeconds)
            guard !Task.isCancelled, let self else { return }
            self.pendingFlush[key] = nil
            await self.flush(key: key)
        }
    }

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
                    model: entry.model
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
            } catch {
                // Keep the local copy; the next edit retries.
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

    // MARK: - Reconciling with the server

    /// Adopts every server row this device does not have a fresher local claim on, and drops any
    /// local row the server no longer has and this device once agreed with.
    public func syncFromServer() async {
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
            // A key with an unwritten local edit is newer than anything the server can report.
            if pendingFlush[row.key] != nil { continue }
            // A key just discarded, whose delete this response may predate.
            if let clearedTime = clearedAt[row.key],
                clock.now().timeIntervalSince(clearedTime) < Self.clearedGraceSeconds
            {
                continue
            }
            if let local = drafts[row.key], local.remoteUpdatedAt == row.updatedAt { continue }
            drafts[row.key] = DraftEntry(
                text: row.text, sessionType: row.sessionType, workingDir: row.workingDir, model: row.model,
                remoteUpdatedAt: row.updatedAt
            )
        }

        for key in Array(drafts.keys) {
            guard !seen.contains(key), let local = drafts[key], local.remoteUpdatedAt != nil, pendingFlush[key] == nil
            else {
                continue
            }
            // Reconciled with the server once and gone from it now: another client sent or
            // discarded it.
            drafts[key] = nil
        }
    }
}
