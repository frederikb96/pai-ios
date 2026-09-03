import Foundation

/// Applies the transcript SSE stream's two content-bearing events. Cursor management, framing,
/// reconnection and backoff are `PaiSseClient`'s job — this only ever runs from inside its
/// `onInit`/`onBatch` callbacks, which already arrive on the main actor.
extension TranscriptStore {

    public func applySseInit(sessionId: String, event: SseInitEvent) {
        touch(sessionId)
        foldLiveEntries(sessionId: sessionId, entries: event.entries)
        evictOldSessions()
        if let tokens = event.sessionTokens { sessionTokens[sessionId] = tokens }
        reconcilePending(sessionId)
    }

    public func applySseBatch(sessionId: String, event: SseBatchEvent) {
        touch(sessionId)
        // Held aside rather than appended while the window is not at the tail — see
        // `foldLiveEntries`'s own doc comment.
        foldLiveEntries(sessionId: sessionId, entries: event.entries)
        evictOldSessions()
        if let tokens = event.sessionTokens { sessionTokens[sessionId] = tokens }
        reconcilePending(sessionId)
    }

    /// The `status` event's `pending_sends`/`last_error` pair, the derived "is a turn running"
    /// flag the transcript uses for its own loading indicator, and the session-level fields
    /// (`state`/`blocker`/`working`/`activity_counts`) recorded in `liveStatus` for whichever
    /// store owns the session list to route into its own rows — see that property's doc comment.
    public func applySseStatus(sessionId: String, event: SseStatusEvent) {
        setDelivery(sessionId: sessionId, pendingSends: event.pendingSends ?? [], lastError: event.lastError)
        isProcessing[sessionId] = event.status == .pending || event.status == .active
        liveStatus[sessionId] = LiveSessionStatus(
            state: event.state, blocker: event.blocker, working: event.working,
            activityCounts: event.activityCounts
        )
    }

    /// Records an `arc` SSE signal — see `TranscriptStore.ArcSignal`'s doc comment for why this
    /// always writes a new value even when the same spec fires twice in a row.
    public func applySseArc(sessionId: String, event: SseArcEvent) {
        let sequence = (liveArc[sessionId]?.sequence ?? 0) + 1
        liveArc[sessionId] = ArcSignal(specUuid: event.specUuid, sequence: sequence)
    }

    /// Called for `onConnected`.
    public func recordSseConnected(sessionId: String, at date: Date) {
        var activity = sseActivity[sessionId] ?? StreamActivity()
        activity.recordConnected(at: date)
        sseActivity[sessionId] = activity
    }

    public func recordSseDisconnected(sessionId: String) {
        var activity = sseActivity[sessionId] ?? StreamActivity()
        activity.recordDisconnected()
        sseActivity[sessionId] = activity
    }

    /// Called for every SSE record, including a bare keepalive with no other effect on this
    /// store — see `PaiSseClient.Callbacks.onActivity`'s doc comment for why that matters.
    public func recordSseActivity(sessionId: String, at date: Date) {
        var activity = sseActivity[sessionId] ?? StreamActivity()
        activity.recordEvent(at: date)
        sseActivity[sessionId] = activity
    }
}
