import Foundation

/// The offline half of ``NotesStore``: what is kept on this phone, and how edits made without a
/// connection reach the server.
///
/// 🚨 The rule everything here serves: the note outbox holds every unsaved edit, online or
/// offline, from the keystroke until the server has it. Nothing that clears or evicts the cache
/// reaches it, and no failure removes an edit from it; only a save the server accepted, or the
/// reader choosing another version, does.
extension NotesStore {

    /// How many conflicts in a row an offline edit meets before it waits for the next trigger
    /// instead of trying again at once.
    static let offlineConflictAttempts = 3
    /// The longest a parked edit waits between automatic retries while the network looks up.
    static let parkedRetryMaxDelay: Duration = .seconds(300)

    var nowMs: Int { Int(now().timeIntervalSince1970 * 1000) }

    /// Whether an edit, rename or favourite is waiting to reach the server.
    public var hasPendingWork: Bool { !awaitingSync.isEmpty || !pendingFieldPatches.isEmpty }

    // MARK: Startup

    /// Reads the cached index, the attachment manifest and every pending edit. Synchronous on
    /// purpose: the list and any unsaved text have to be there in the first frame.
    func restoreFromDisk() {
        let started = Date()
        let cachedRows = cache.loadIndex()?.notes ?? []
        serverRows = Dictionary(cachedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in cache.loadAttachmentManifest() {
            attachmentManifest[CachedAttachmentKey.of(containerId: entry.containerId, path: entry.path)] = entry
        }
        for patch in outbox.loadFieldPatches() {
            pendingFieldPatches[patch.noteId] = patch
        }
        for edit in outbox.loadEdits() {
            let id = edit.noteId
            drafts[id] = edit.body
            details[id] = edit.base
            detailVersion[id, default: 0] += 1
            editedAtMs[id] = edit.editedAtMs
            syncAttempts[id] = edit.attempts
            if let conflict = edit.raisedConflict {
                // Asked before the app went away and never answered: ask again rather than let a
                // relaunch decide.
                saveStates[id] = .conflict(conflict)
            } else {
                saveStates[id] = .waitingForNetwork
                awaitingSync.insert(id)
            }
        }
        notes = overlaid(cachedRows)
        indexLoadMs = Date().timeIntervalSince(started) * 1000
    }

    /// Puts this phone's copy of a note on screen before its request goes out. Never over a
    /// detail already held: that one is either newer or the base of an unsaved edit.
    func hydrateFromCache(id: String) {
        guard details[id] == nil, let cached = cache.loadBody(noteId: id) else { return }
        details[id] = cached
        detailVersion[id, default: 0] += 1
        bumpExternalRevision(id)
    }

    // MARK: Connectivity

    /// Fed from the network path monitor. While the path is down no notes request is attempted
    /// at all — an edit is only written to disk — so nothing sits through a timeout.
    public func setPathSatisfied(_ satisfied: Bool) {
        let before = pathSatisfied
        pathSatisfied = satisfied
        if satisfied, before == false { transportDown = false }
        if !satisfied {
            parkedRetry?.cancel()
            parkedRetry = nil
        }
    }

    /// What a failed online-only request tells the reader: without a connection, that the
    /// operation needs one (``NoteOnlineOnly``); otherwise what the server said.
    func failureMessage(_ error: Error, needing operation: NoteOnlineOnly, otherwise fallback: String) -> String {
        if NoteSyncFailure.isTransport(error) {
            transportDown = true
            return operation.message
        }
        return (error as? PaiError)?.userMessage ?? fallback
    }

    func requestSucceeded() {
        transportDown = false
        parkedRetryAttempt = 0
    }

    /// Re-fetches the index when this run has not fetched it in the last `maxAge` seconds. The
    /// list calls this on appear and on return to the foreground; pull-to-refresh always fetches.
    public func refreshIfStale(maxAge: TimeInterval = 60) async {
        if let fetched = indexFetchedAt, now().timeIntervalSince(fetched) < maxAge { return }
        await refresh()
    }

    // MARK: The index

    func adoptIndex(_ fetched: [NoteSummary]) {
        serverRows = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexFetchedAt = now()
        let shown = overlaid(fetched)
        // An identical index is not assigned, so a refresh that changed nothing re-renders nothing.
        if shown != notes { notes = shown }
    }

    func persistIndex(_ fetched: [NoteSummary]) async {
        let cache = self.cache
        let index = CachedNoteIndex(notes: fetched, fetchedAtMs: nowMs)
        await Task.detached { cache.saveIndex(index) }.value
    }

    func overlaid(_ rows: [NoteSummary]) -> [NoteSummary] {
        guard hasPendingWork else { return rows }
        return rows.map(overlay)
    }

    /// A row as it should read with this phone's unsynced changes on it: the local name and
    /// favourite, and an offline-edited note dated by its edit so it sorts where an online edit
    /// would.
    func overlay(_ row: NoteSummary) -> NoteSummary {
        let patch = pendingFieldPatches[row.id]
        var updatedAtMs = row.updatedAtMs
        if awaitingSync.contains(row.id), let edited = editedAtMs[row.id], edited > updatedAtMs {
            updatedAtMs = edited
        }
        guard patch != nil || updatedAtMs != row.updatedAtMs else { return row }
        return NoteSummary(
            id: row.id, name: patch?.name ?? row.name, summary: row.summary, containerId: row.containerId,
            favourite: patch?.favourite ?? row.favourite, tags: row.tags, updatedAtMs: updatedAtMs,
            pendingDelete: row.pendingDelete, shared: row.shared)
    }

    func reoverlayRow(id: String, base: NoteSummary? = nil) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let shown = overlay(base ?? notes[index])
        if shown != notes[index] { notes[index] = shown }
    }

    // MARK: Bodies

    func cacheBody(_ detail: NoteDetail) {
        cache.saveBody(detail)
        bodyStamps?[detail.id] = detail.updatedAtMs
    }

    func startBodyMaintenance(index: [NoteSummary]) {
        bodyMaintenance?.cancel()
        bodyMaintenance = Task { [weak self] () -> Void in await self?.maintainCachedBodies(index: index) }
    }

    /// After each index fetch: drops the copies of notes that are gone, refetches copies the
    /// index says are older than the server's, and fetches favourites not yet on this phone.
    /// One request at a time, behind whatever the reader is doing.
    ///
    /// A note held in memory is left alone. It is open, or was this run, and its own screen
    /// refreshes it; refetching it here would move the baseline of an edit typed over it.
    func maintainCachedBodies(index: [NoteSummary]) async {
        let cache = self.cache
        if bodyStamps == nil {
            bodyStamps = await Task.detached { cache.bodyStamps() }.value
        }
        guard let stamps = bodyStamps else { return }
        let rows = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in stamps.keys {
            guard let row = rows[id], !row.pendingDelete else {
                cache.removeBody(noteId: id)
                bodyStamps?[id] = nil
                continue
            }
        }
        var wanted: [String] = []
        for row in index where !row.pendingDelete {
            if let stamp = stamps[row.id] {
                if stamp < row.updatedAtMs { wanted.append(row.id) }
            } else if row.favourite {
                wanted.append(row.id)
            }
        }
        for id in wanted {
            guard !Task.isCancelled, pathSatisfied != false else { return }
            guard details[id] == nil, drafts[id] == nil else { continue }
            do {
                let detail = try await api.getNote(id: id)
                requestSucceeded()
                guard details[id] == nil, drafts[id] == nil else { continue }
                cacheBody(detail)
            } catch {
                if NoteSyncFailure.isTransport(error) {
                    transportDown = true
                    return
                }
            }
        }
    }

    // MARK: The outbox

    /// Makes the note outbox agree with memory for one note: the current draft and the version it
    /// was typed over, or nothing once there is no draft. Called wherever either changes.
    func syncOutbox(id: String) {
        guard let draft = drafts[id] else {
            outbox.removeEdit(noteId: id)
            editedAtMs[id] = nil
            syncAttempts[id] = nil
            if awaitingSync.remove(id) != nil { reoverlayRow(id: id, base: serverRows[id]) }
            return
        }
        // A draft with no detail cannot be saved either (`performSave` needs both); it never
        // arises from the editor, which only shows a note it has a body for.
        guard let base = details[id] else { return }
        var conflict: NoteConflict?
        if case .conflict(let raised) = saveStates[id] { conflict = raised }
        outbox.saveEdit(
            NotePendingEdit(
                noteId: id, body: draft, base: base, editedAtMs: editedAtMs[id] ?? nowMs,
                attempts: syncAttempts[id] ?? 0, raisedConflict: conflict, awaitingSync: awaitingSync.contains(id)))
    }

    /// The edit could not reach the server: it stays on this phone, marked as an offline edit,
    /// and goes out on the next trigger.
    func park(id: String) {
        saveStates[id] = .waitingForNetwork
        awaitingSync.insert(id)
        syncOutbox(id: id)
        reoverlayRow(id: id)
        scheduleParkedRetry()
    }

    func settleSave(id: String, caughtUp: Bool, overwrote: Bool) {
        if drafts[id] == nil, caughtUp {
            syncCounters.replayed += 1
            if overwrote { syncCounters.conflictsResolved += 1 }
        }
        syncOutbox(id: id)
    }

    func handleSaveFailure(id: String, error: Error) {
        switch NoteSyncFailure.classify(error) {
        case .transport:
            transportDown = true
            park(id: id)
        case .retryLater:
            park(id: id)
        case .noteGone:
            saveStates[id] = .failed("This note was deleted elsewhere. Your text is kept on this phone.")
            syncOutbox(id: id)
        case .rejected(let message):
            saveStates[id] = .failed(message)
            syncOutbox(id: id)
        }
    }

    /// The conflict policy for an edit made offline: it is written over the server's version,
    /// conditionally on that version's hash and marked `source: offline`, so the server keeps
    /// the version it replaces in the note's history. No question is asked and the text on screen
    /// is never the one discarded.
    func keepOfflineEdit(id: String, body: String, baseline: NoteDetail, over conflict: NoteConflict) async {
        var current = conflict
        for _ in 0..<Self.offlineConflictAttempts {
            syncAttempts[id, default: 0] += 1
            #if DEBUG
                DebugLogBuffer.shared.append(
                    .info, "notes-store",
                    "keepOfflineEdit(\(id)) writing over \(current.currentHash.prefix(8)) with source=offline")
            #endif
            let result: NoteSaveResult
            do {
                result = try await api.patchNote(
                    id: id, body: body, frontmatter: baseline.frontmatter, name: nil, summary: nil,
                    favourite: nil, containerId: nil, expectedHash: current.currentHash,
                    source: NoteWriteSource.offline)
                requestSucceeded()
            } catch {
                handleSaveFailure(id: id, error: error)
                return
            }
            switch result {
            case .saved(let detail):
                setDetail(detail, for: id)
                finishWrite(id: id, sent: body, row: detail.summaryRow)
                settleSave(id: id, caughtUp: true, overwrote: true)
                onSyncNotice?(.overwroteNewerVersion(noteId: id, name: name(for: id) ?? NoteNaming.untitled))
                return
            case .conflict(let again):
                if (again.body ?? "") == body {
                    setDetail(baseline.adoptingHash(again), for: id)
                    finishWrite(id: id, sent: body, row: nil)
                    settleSave(id: id, caughtUp: true, overwrote: false)
                    return
                }
                current = again
            }
        }
        #if DEBUG
            DebugLogBuffer.shared.append(
                .warning, "notes-store",
                "keepOfflineEdit(\(id)) met \(Self.offlineConflictAttempts) conflicts in a row; waiting for the next sync"
            )
        #endif
        saveStates[id] = .waitingForNetwork
        syncOutbox(id: id)
    }

    /// What every accepted write does with the draft: clear it if nothing was typed while the
    /// request was out, otherwise save again.
    private func finishWrite(id: String, sent: String, row: NoteSummary?) {
        if drafts[id] == sent {
            drafts[id] = nil
            saveStates[id] = .clean
        } else {
            saveStates[id] = .dirty
            scheduleSave(id: id)
        }
        if let row, let index = notes.firstIndex(where: { $0.id == id }) { notes[index] = row }
    }

    /// Tries parked edits again on its own while the network looks up, backing off from
    /// `parkedRetryBaseDelay` to five minutes. A server error or a dead Wi-Fi gives no "network
    /// regained" signal, so without this an edit would wait for the next foreground.
    func scheduleParkedRetry() {
        guard pathSatisfied != false, parkedRetry == nil, hasPendingWork else { return }
        let factor = 1 << min(parkedRetryAttempt, 5)
        let delay = min(parkedRetryBaseDelay * factor, Self.parkedRetryMaxDelay)
        parkedRetryAttempt += 1
        parkedRetry = Task { [weak self] () -> Void in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.parkedRetry = nil
            await self?.resumeSync()
        }
    }

    // MARK: Renames and favourites made offline

    func queueFieldPatch(id: String, name: String?, favourite: Bool?) {
        var patch = pendingFieldPatches[id] ?? NotePendingFieldPatch(noteId: id, editedAtMs: nowMs)
        if let name { patch.name = name }
        if let favourite { patch.favourite = favourite }
        patch.editedAtMs = nowMs
        pendingFieldPatches[id] = patch
        outbox.saveFieldPatch(patch)
        reoverlayRow(id: id)
        scheduleParkedRetry()
    }

    private enum FieldOutcome {
        case done(NoteDetail?)
        case keep
        case refused(String)
    }

    private func sendField(id: String, name: String?, favourite: Bool?) async -> FieldOutcome {
        do {
            let result = try await api.patchNote(
                id: id, body: nil, frontmatter: nil, name: name, summary: nil, favourite: favourite,
                containerId: nil, expectedHash: nil, source: nil)
            requestSucceeded()
            switch result {
            case .saved(let detail): return .done(detail)
            case .conflict: return .refused("the note changed on the server")
            }
        } catch {
            switch NoteSyncFailure.classify(error) {
            case .transport:
                transportDown = true
                return .keep
            case .retryLater: return .keep
            case .noteGone: return .refused("the note no longer exists")
            case .rejected(let message): return .refused(message)
            }
        }
    }

    /// Sends a queued rename, then a queued favourite. A field is cleared only if it still holds
    /// what was sent, so a change made while the request was out is kept for the next pass.
    func replayFieldPatch(id: String) async {
        guard let patch = pendingFieldPatches[id] else { return }
        var latestRow: NoteSummary?
        if let name = patch.name {
            switch await sendField(id: id, name: name, favourite: nil) {
            case .done(let detail):
                latestRow = detail?.summaryRow ?? latestRow
                adoptFieldResult(detail, id: id)
                clearField(id: id) { $0.name == name ? $0.clearingName() : $0 }
                syncCounters.fieldsSynced += 1
            case .keep:
                return
            case .refused(let reason):
                clearField(id: id) { $0.name == name ? $0.clearingName() : $0 }
                latestRow = notes.first { $0.id == id }.map {
                    $0.renamed(details[id]?.name ?? serverRows[id]?.name ?? $0.name)
                }
                onSyncNotice?(.renameRefused(noteId: id, attempted: name, reason: reason))
            }
        }
        if let favourite = pendingFieldPatches[id]?.favourite {
            switch await sendField(id: id, name: nil, favourite: favourite) {
            case .done(let detail):
                latestRow = detail?.summaryRow ?? latestRow
                adoptFieldResult(detail, id: id)
                clearField(id: id) { $0.favourite == favourite ? $0.clearingFavourite() : $0 }
                syncCounters.fieldsSynced += 1
            case .keep:
                break
            case .refused:
                clearField(id: id) { $0.favourite == favourite ? $0.clearingFavourite() : $0 }
            }
        }
        reoverlayRow(id: id, base: latestRow)
    }

    private func clearField(id: String, _ change: (NotePendingFieldPatch) -> NotePendingFieldPatch) {
        guard let current = pendingFieldPatches[id] else { return }
        let next = change(current)
        if next.name == nil, next.favourite == nil {
            pendingFieldPatches[id] = nil
            outbox.removeFieldPatch(noteId: id)
        } else if next != current {
            pendingFieldPatches[id] = next
            outbox.saveFieldPatch(next)
        }
    }

    /// A rename's answer is the whole note. It becomes the baseline only when no edit is typed
    /// over the current one, since moving an edit's baseline would let it overwrite whatever the
    /// server holds now.
    private func adoptFieldResult(_ detail: NoteDetail?, id: String) {
        guard let detail else { return }
        serverRows[id] = detail.summaryRow
        if drafts[id] == nil, inFlightSaves[id] == nil { setDetail(detail, for: id) }
    }

    // MARK: Sync

    /// Sends everything this phone holds for one note: a queued rename or favourite, then the
    /// body. What ``loadNote(id:)`` does instead of refreshing a note with an edit waiting.
    func replayPending(id: String) async {
        await replayFieldPatch(id: id)
        guard awaitingSync.contains(id), drafts[id] != nil else { return }
        if case .conflict = saveState(for: id) { return }
        await flush(id: id)
    }

    /// Sends every edit, rename and favourite made offline, one note at a time, then refreshes
    /// the index. Each body goes through the same single-flight save an online edit uses, so the
    /// newest text is always the last one sent. Overlapping calls share one pass.
    ///
    /// Triggered by the network coming back, the app returning to the foreground, the first
    /// successful index fetch after an outage, pull-to-refresh, the offline banner's "Sync now"
    /// and, for one note, opening it.
    public func resumeSync() async {
        if let running = syncTask {
            await running.value
            return
        }
        // Unstructured, so a caller's cancellation (a view going away) cannot cancel the
        // requests of a sync that other callers are waiting on.
        let task = Task { [weak self] () -> Void in await self?.runSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    private func runSync() async {
        syncCounters = NoteSyncReport()
        // Runs on every return to the foreground; with nothing waiting it costs nothing.
        guard hasPendingWork else {
            lastSyncReport = syncCounters
            return
        }
        parkedRetry?.cancel()
        parkedRetry = nil
        for patch in pendingFieldPatches.values.sorted(by: { $0.editedAtMs < $1.editedAtMs }) {
            await replayFieldPatch(id: patch.noteId)
        }
        let ids = awaitingSync.sorted { (editedAtMs[$0] ?? 0, $0) < (editedAtMs[$1] ?? 0, $1) }
        for id in ids {
            guard drafts[id] != nil else {
                syncOutbox(id: id)
                continue
            }
            if case .conflict = saveState(for: id) { continue }
            await flush(id: id)
            // One edit that could not get through says the rest cannot either.
            if saveState(for: id) == .waitingForNetwork, transportDown || pathSatisfied == false { break }
        }
        if !transportDown, pathSatisfied != false { await refresh() }
        syncCounters.stillPending = awaitingSync.count + pendingFieldPatches.count
        lastSyncReport = syncCounters
        let plain = syncCounters.replayed - syncCounters.conflictsResolved
        if plain > 0 { onSyncNotice?(.synced(count: plain)) }
        if syncCounters.stillPending > 0 { scheduleParkedRetry() }
    }

    // MARK: Attachments on disk

    func readCachedAttachment(_ entry: CachedAttachment) async -> Data? {
        let cache = self.cache
        let fileId = entry.fileId
        let data = await Task.detached { cache.readAttachment(fileId: fileId) }.value
        let key = CachedAttachmentKey.of(containerId: entry.containerId, path: entry.path)
        if data == nil {
            // The blob is gone (cleared, or never written): forget it rather than keep asking.
            if attachmentManifest[key]?.fileId == fileId { attachmentManifest[key] = nil }
        } else {
            attachmentManifest[key]?.lastUsedMs = nowMs
        }
        return data
    }

    func storeAttachment(_ data: Data, containerId: String, path: String) async {
        guard NotesCacheBudget.admits(byteCount: data.count, budgetBytes: cacheBudgetBytes) else { return }
        let key = CachedAttachmentKey.of(containerId: containerId, path: path)
        let record = freshInventories[containerId]?.first { $0.relPath == path }
        let fileId = UUID().uuidString
        let cache = self.cache
        let wrote = await Task.detached { cache.writeAttachment(data, fileId: fileId) }.value
        guard wrote else { return }
        let replaced = attachmentManifest[key]
        attachmentManifest[key] = CachedAttachment(
            fileId: fileId, containerId: containerId, path: path, byteCount: data.count,
            sizeBytes: record?.sizeBytes, mtimeMs: record?.mtimeMs, lastUsedMs: nowMs)
        if let replaced {
            let oldId = replaced.fileId
            await Task.detached { cache.removeAttachment(fileId: oldId) }.value
        }
        await persistManifestAndEvict()
    }

    func dropCachedAttachment(containerId: String, path: String) async {
        let key = CachedAttachmentKey.of(containerId: containerId, path: path)
        guard let entry = attachmentManifest.removeValue(forKey: key) else { return }
        let cache = self.cache
        let fileId = entry.fileId
        await Task.detached { cache.removeAttachment(fileId: fileId) }.value
        await persistManifestAndEvict()
    }

    /// Writes the manifest and evicts down to the budget. Each call waits for the one before, so
    /// the manifest on disk is always the latest snapshot, never an older one finishing last.
    func persistManifestAndEvict() async {
        let previous = manifestWrite
        let entries = Array(attachmentManifest.values)
        let budget = cacheBudgetBytes
        let cache = self.cache
        let task = Task<[String], Never> {
            _ = await previous?.value
            return await Task.detached { () -> [String] in
                let evicted = NotesCacheBudget.evictions(
                    attachments: entries, metadataBytes: cache.metadataBytes(), budgetBytes: budget)
                for fileId in evicted { cache.removeAttachment(fileId: fileId) }
                let kept = entries.filter { !evicted.contains($0.fileId) }
                cache.saveAttachmentManifest(kept)
                return evicted
            }.value
        }
        manifestWrite = task
        let evicted = Set(await task.value)
        if !evicted.isEmpty {
            attachmentManifest = attachmentManifest.filter { !evicted.contains($0.value.fileId) }
        }
    }

    // MARK: Settings

    /// Applies the budget from Settings and evicts down to it at once. Called at launch too,
    /// which is the launch-time eviction pass.
    public func setCacheBudget(_ bytes: Int) {
        cacheBudgetBytes = bytes
        Task { [weak self] in await self?.persistManifestAndEvict() }
    }

    /// Empties the cache: index, bodies, inventories and files. Unsaved edits are a different
    /// store and are not touched; what is on screen stays until the next fetch replaces it.
    public func clearCache() async {
        _ = await manifestWrite?.value
        let cache = self.cache
        await Task.detached { cache.clear() }.value
        attachmentManifest = [:]
        bodyStamps = [:]
        freshInventories = [:]
        attachmentCache = NoteAttachmentCache()
    }

    public func cacheStatus() async -> NotesCacheStatus {
        let cache = self.cache
        let (metadata, bodies) = await Task.detached { (cache.metadataBytes(), cache.bodyStamps().count) }.value
        let attachmentBytes = attachmentManifest.values.reduce(0) { $0 + $1.byteCount }
        var pending = awaitingSync.union(drafts.keys).sorted().map { id in
            NotePendingSummary(
                noteId: id, kind: "body", state: Self.label(saveState(for: id)), attempts: syncAttempts[id] ?? 0)
        }
        pending += pendingFieldPatches.keys.sorted().map {
            NotePendingSummary(noteId: $0, kind: "fields", state: "queued", attempts: 0)
        }
        return NotesCacheStatus(
            isOffline: isOffline, indexCount: notes.count,
            indexFetchedAtMs: indexFetchedAt.map { Int($0.timeIntervalSince1970 * 1000) },
            indexLoadMs: indexLoadMs, cachedBodyCount: bodies, cachedAttachmentCount: attachmentManifest.count,
            cacheBytes: metadata + attachmentBytes, budgetBytes: cacheBudgetBytes, pending: pending,
            lastSyncReport: lastSyncReport)
    }

    public static func label(_ state: NoteSaveState) -> String {
        switch state {
        case .clean: "clean"
        case .dirty: "dirty"
        case .saving: "saving"
        case .conflict: "conflict"
        case .failed: "failed"
        case .waitingForNetwork: "waitingForNetwork"
        }
    }
}

/// The attachment manifest's key: a container and a path, joined by a character no path holds.
enum CachedAttachmentKey {
    static func of(containerId: String, path: String) -> String { "\(containerId)\u{0}\(path)" }
}

extension NotePendingFieldPatch {
    fileprivate func clearingName() -> NotePendingFieldPatch {
        var copy = self
        copy.name = nil
        return copy
    }

    fileprivate func clearingFavourite() -> NotePendingFieldPatch {
        var copy = self
        copy.favourite = nil
        return copy
    }
}

extension NoteSummary {
    /// Every field passed explicitly, for the reason ``NoteDetail/adoptingHash(_:)`` gives.
    fileprivate func renamed(_ name: String) -> NoteSummary {
        NoteSummary(
            id: id, name: name, summary: summary, containerId: containerId, favourite: favourite, tags: tags,
            updatedAtMs: updatedAtMs, pendingDelete: pendingDelete, shared: shared)
    }
}
