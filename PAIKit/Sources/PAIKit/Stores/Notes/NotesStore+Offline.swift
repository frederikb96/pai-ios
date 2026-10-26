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

    /// Whether an edit, rename or favourite is waiting to reach the server by itself. A refused
    /// edit is not: it waits for the reader (``keptTexts``).
    public var hasPendingWork: Bool {
        !awaitingSync.isEmpty || !unsentAtLaunch.isEmpty || !pendingFieldPatches.isEmpty
    }

    /// Whether opening this note should send what this phone holds for it rather than reload it.
    func isWaitingToSend(_ id: String) -> Bool {
        awaitingSync.contains(id) || unsentAtLaunch.contains(id) || pendingFieldPatches[id] != nil
    }

    // MARK: Startup

    /// Reads the cached index, the attachment manifest and every pending edit, and drops any
    /// attachment file the manifest does not name. Synchronous on purpose: the list and any
    /// unsaved text have to be there in the first frame, and nothing else touches the cache yet.
    ///
    /// Each edit comes back as what it was when the app went away:
    /// - a conflict the reader was shown and never answered is asked again;
    /// - an edit the server refused stays refused, with its text, until the reader acts;
    /// - an edit that had failed to reach the server is an offline edit again (``awaitingSync``);
    /// - an edit that never failed (typed online, the app killed first) is sent as an ordinary
    ///   save, so a conflict it meets raises the banner exactly as it would have online.
    func restoreFromDisk() {
        let started = Date()
        let cachedRows = cache.loadIndex()?.notes ?? []
        serverRows = Dictionary(cachedRows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in cache.loadAttachmentManifest() {
            attachmentManifest[CachedAttachmentKey.of(containerId: entry.containerId, path: entry.path)] = entry
        }
        sweepUnlistedAttachments()
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
            if edit.waitedForServer { waitedForServer.insert(id) }
            if let conflict = edit.raisedConflict {
                saveStates[id] = .conflict(conflict)
            } else if let refusal = edit.refusal {
                editRefusals[id] = refusal
                saveStates[id] = .failed(refusal)
            } else {
                saveStates[id] = .waitingForNetwork
                if edit.awaitingSync { awaitingSync.insert(id) } else { unsentAtLaunch.insert(id) }
            }
        }
        quarantined = outbox.loadQuarantined()
        notes = overlaid(cachedRows)
        indexLoadMs = Date().timeIntervalSince(started) * 1000
    }

    /// A blob written just before the app died, before the manifest naming it was, is outside both
    /// the budget and the usage figure, and nothing would ever read or evict it.
    private func sweepUnlistedAttachments() {
        let listed = Set(attachmentManifest.values.map(\.fileId))
        for fileId in cache.attachmentFileIds() where !listed.contains(fileId) {
            cache.removeAttachment(fileId: fileId)
        }
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
            markTransportDown()
            return operation.message
        }
        return (error as? PaiError)?.userMessage ?? fallback
    }

    /// Any notes request that got an answer: the server is reachable, whatever this phone
    /// concluded from an earlier failure.
    func requestSucceeded() {
        transportDown = false
    }

    /// A request failed in transport. Ignored while the caller is cancelled: a request abandoned
    /// on purpose says nothing about the network.
    func markTransportDown() {
        guard !Task.isCancelled else { return }
        transportDown = true
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
        let index = CachedNoteIndex(notes: fetched)
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
                switch NoteSyncFailure.classify(error) {
                case .cancelled:
                    return
                case .transport:
                    markTransportDown()
                    return
                default:
                    continue
                }
            }
        }
    }

    // MARK: The outbox

    /// Makes the note outbox agree with memory for one note, at once: the current draft and the
    /// version it was typed over, or nothing once there is no draft. Called wherever either
    /// changes, and before every request.
    func syncOutbox(id: String) {
        guard drafts[id] != nil else {
            outboxWriter.remove(noteId: id)
            editedAtMs[id] = nil
            syncAttempts[id] = nil
            editRefusals[id] = nil
            waitedForServer.remove(id)
            unsentAtLaunch.remove(id)
            if awaitingSync.remove(id) != nil { reoverlayRow(id: id, base: serverRows[id]) }
            return
        }
        guard let record = pendingRecord(id: id) else { return }
        outboxWriter.save(record)
    }

    /// ``syncOutbox(id:)`` for a keystroke: the record is written once typing pauses for
    /// ``NotesStore/outboxWriteDelay``, off the main actor.
    func persistDraftSoon(id: String) {
        guard let record = pendingRecord(id: id) else { return }
        outboxWriter.saveSoon(record)
    }

    /// Everything the outbox keeps for a note's draft. `nil` for a draft with no detail, which
    /// cannot be saved either (`performSave` needs both) and never arises from the editor, which
    /// only shows a note it has a body for.
    private func pendingRecord(id: String) -> NotePendingEdit? {
        guard let draft = drafts[id], let base = details[id] else { return nil }
        var conflict: NoteConflict?
        if case .conflict(let raised) = saveStates[id] { conflict = raised }
        return NotePendingEdit(
            noteId: id, body: draft, base: base, editedAtMs: editedAtMs[id] ?? nowMs,
            attempts: syncAttempts[id] ?? 0, raisedConflict: conflict, awaitingSync: awaitingSync.contains(id),
            waitedForServer: waitedForServer.contains(id), refusal: editRefusals[id])
    }

    /// The edit could not reach the server: it stays on this phone, marked as an offline edit,
    /// and goes out on the next trigger. `forServer` is a server error with the network up; an
    /// edit that has been without a connection at any point stays an offline edit.
    func park(id: String, forServer: Bool) {
        if !forServer {
            waitedForServer.remove(id)
        } else if !awaitingSync.contains(id) {
            waitedForServer.insert(id)
        }
        saveStates[id] = .waitingForNetwork
        awaitingSync.insert(id)
        syncOutbox(id: id)
        reoverlayRow(id: id)
        scheduleParkedRetry()
    }

    /// Bookkeeping after the server accepted a save. The retry backoff starts over only here, on
    /// a save that got through, never on some other request succeeding while this one keeps
    /// failing.
    func settleSave(id: String, caughtUp: Bool, overwrote: Bool) {
        parkedRetryAttempt = 0
        if drafts[id] == nil, caughtUp {
            syncCounters.replayed += 1
            if overwrote {
                syncCounters.conflictsResolved += 1
            } else if waitedForServer.contains(id) {
                serverWaitReplays += 1
            }
        }
        syncOutbox(id: id)
    }

    func handleSaveFailure(id: String, error: Error) {
        switch NoteSyncFailure.classify(error) {
        case .transport:
            markTransportDown()
            park(id: id, forServer: false)
        case .retryLater:
            park(id: id, forServer: true)
        case .noteGone:
            refuse(id: id, NoteSyncFailure.noteGoneRefusal)
        case .rejected(let message):
            refuse(id: id, message)
        case .cancelled:
            // Not an answer from anywhere; the edit is still unsaved, so it goes out again.
            saveStates[id] = .dirty
            syncOutbox(id: id)
            scheduleSave(id: id)
        }
    }

    /// The server will not take this edit as it stands. It leaves the sync queue, since sending it
    /// again gets the same answer, and stays on this phone with the reason until the reader
    /// keeps or discards it.
    private func refuse(id: String, _ message: String) {
        editRefusals[id] = message
        saveStates[id] = .failed(message)
        waitedForServer.remove(id)
        unsentAtLaunch.remove(id)
        if awaitingSync.remove(id) != nil { reoverlayRow(id: id, base: serverRows[id]) }
        syncOutbox(id: id)
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
                let madeOffline = !waitedForServer.contains(id)
                setDetail(detail, for: id)
                finishWrite(id: id, sent: body, row: detail.summaryRow)
                settleSave(id: id, caughtUp: true, overwrote: true)
                onSyncNotice?(
                    .overwroteNewerVersion(
                        noteId: id, name: name(for: id) ?? NoteNaming.untitled, madeOffline: madeOffline))
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

    /// What every accepted write does with the draft: clear it only if nothing was typed while
    /// the request was out — otherwise the newer keystrokes would be dropped and the editor would
    /// show text the server has never seen while reporting itself clean — and save again if
    /// something was. `row` updates the note's list row; `insertingRow` adds it when the list
    /// does not hold it.
    func finishWrite(id: String, sent: String, row: NoteSummary?, insertingRow: Bool = false) {
        if drafts[id] == sent {
            drafts[id] = nil
            saveStates[id] = .clean
        } else {
            saveStates[id] = .dirty
            scheduleSave(id: id)
        }
        guard let row else { return }
        if let index = notes.firstIndex(where: { $0.id == id }) {
            notes[index] = row
        } else if insertingRow {
            notes.insert(row, at: 0)
        }
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
            case .saved(let detail):
                parkedRetryAttempt = 0
                return .done(detail)
            case .conflict: return .refused("the note changed on the server")
            }
        } catch {
            switch NoteSyncFailure.classify(error) {
            case .transport:
                markTransportDown()
                return .keep
            case .retryLater, .cancelled: return .keep
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

    /// The one rule for a rename's, favourite's or summary's answer, online or replayed. The answer
    /// is the whole note. It becomes the baseline only when no edit is typed over the current one
    /// and no save is out: moving an edit's baseline would let its next save pass the hash check
    /// against a body it never saw and overwrite whatever the server holds now. Under an edit only
    /// the fields the answer was about move (``NoteDetail/adoptingFields(of:)``), and the outbox
    /// is brought along so memory and disk keep one baseline.
    func adoptFieldResult(_ detail: NoteDetail?, id: String) {
        guard let detail else { return }
        serverRows[id] = detail.summaryRow
        guard drafts[id] != nil || inFlightSaves[id] != nil, let baseline = details[id] else {
            setDetail(detail, for: id)
            return
        }
        setDetail(baseline.adoptingFields(of: detail), for: id)
        if drafts[id] != nil { syncOutbox(id: id) }
    }

    // MARK: Sync

    /// Sends everything this phone holds for one note: the body, then a queued rename or
    /// favourite (the order ``resumeSync()`` explains). What ``loadNote(id:)`` does instead of
    /// refreshing a note with an edit waiting.
    func replayPending(id: String) async {
        if awaitingSync.contains(id) || unsentAtLaunch.contains(id), drafts[id] != nil {
            if case .conflict = saveState(for: id) {} else { await flush(id: id) }
        }
        await replayFieldPatch(id: id)
    }

    /// Sends every waiting edit, then every rename and favourite made offline, one note at a time,
    /// then refreshes the index. Each body goes through the same single-flight save an online edit
    /// uses, so the newest text is always the last one sent. Overlapping calls share one pass.
    ///
    /// Bodies go first because a rename makes the server rewrite `[[Old]]` to `[[New]]` in every
    /// note linking to it. A linking note whose edit was still waiting would then meet that
    /// rewrite as a conflict and, as an offline edit, write the old link back over it; sent first,
    /// its body is what the rewrite applies to. A rename made on the web while this phone was
    /// offline cannot be ordered away like that: the waiting edit still wins over the rewrite.
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
        serverWaitReplays = 0
        // Runs on every return to the foreground; with nothing waiting it costs nothing.
        guard hasPendingWork else {
            lastSyncReport = syncCounters
            return
        }
        parkedRetry?.cancel()
        parkedRetry = nil
        let ids = awaitingSync.union(unsentAtLaunch).sorted {
            (editedAtMs[$0] ?? 0, $0) < (editedAtMs[$1] ?? 0, $1)
        }
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
        if !transportDown, pathSatisfied != false {
            for patch in pendingFieldPatches.values.sorted(by: { $0.editedAtMs < $1.editedAtMs }) {
                await replayFieldPatch(id: patch.noteId)
            }
        }
        if !transportDown, pathSatisfied != false { await refresh() }
        syncCounters.stillPending = awaitingSync.count + unsentAtLaunch.count + pendingFieldPatches.count
        lastSyncReport = syncCounters
        let plain = syncCounters.replayed - syncCounters.conflictsResolved
        let offlinePlain = plain - serverWaitReplays
        if offlinePlain > 0 { onSyncNotice?(.synced(count: offlinePlain)) }
        if serverWaitReplays > 0 { onSyncNotice?(.synced(count: serverWaitReplays, madeOffline: false)) }
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
    /// store and are not touched; what is on screen stays until the next fetch replaces it. The
    /// index rows of notes with something waiting are written back, so a relaunch without a
    /// connection still lists them and their edits stay reachable.
    public func clearCache() async {
        _ = await manifestWrite?.value
        let cache = self.cache
        let waiting = Set(drafts.keys).union(awaitingSync).union(pendingFieldPatches.keys)
        let keptRows = serverRows.values.filter { waiting.contains($0.id) }.sorted { $0.id < $1.id }
        await Task.detached {
            cache.clear()
            if !keptRows.isEmpty { cache.saveIndex(CachedNoteIndex(notes: keptRows)) }
        }.value
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

    // MARK: Text that cannot sync by itself

    /// Every text this phone holds that will not reach the server without the reader: edits the
    /// server refused (most often because the note was deleted elsewhere, which also takes it off
    /// the list) and outbox files this build could not read.
    public var keptTexts: [NoteKeptText] {
        let refused = editRefusals.keys.sorted().compactMap { id -> NoteKeptText? in
            guard let text = drafts[id], let reason = editRefusals[id] else { return nil }
            return NoteKeptText(
                origin: .refusedEdit(noteId: id), title: name(for: id) ?? NoteNaming.untitled, reason: reason,
                text: text)
        }
        let unreadable = quarantined.map { kept in
            NoteKeptText(
                origin: .unreadable(fileId: kept.id),
                title: kept.noteId.flatMap { name(for: $0) } ?? "An unsaved edit",
                reason: "Kept by another version of the app in a form this one cannot read.", text: kept.text)
        }
        return refused + unreadable
    }

    /// Removes a kept text for good — the reader's answer once it is copied somewhere, or not
    /// wanted.
    public func discardKeptText(_ kept: NoteKeptText) {
        switch kept.origin {
        case .refusedEdit(let id):
            discardEdit(id: id)
        case .unreadable(let fileId):
            outbox.removeQuarantined(id: fileId)
            quarantined.removeAll { $0.id == fileId }
        }
    }

    /// Drops the unsaved text of a note whose save failed, on disk too, and shows the note as the
    /// server last sent it. Only for a failed save: any other state either sends the text by
    /// itself or asks the reader a question of its own.
    public func discardEdit(id: String) {
        guard case .failed = saveState(for: id), drafts[id] != nil else { return }
        saveTasks[id]?.cancel()
        saveTasks[id] = nil
        drafts[id] = nil
        saveStates[id] = .clean
        bumpExternalRevision(id)
        syncOutbox(id: id)
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
