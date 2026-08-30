import Foundation

/// Applies the transcript SSE stream's two content-bearing events. Cursor management, framing,
/// reconnection and backoff are `PaiSseClient`'s job — this only ever runs from inside its
/// `onInit`/`onBatch` callbacks, which already arrive on the main actor.
extension TranscriptStore {

    public func applySseInit(sessionId: String, event: SseInitEvent) {
        touch(sessionId)
        merge(event.entries, into: sessionId)
        evictOldSessions()
        if let tokens = event.sessionTokens { sessionTokens[sessionId] = tokens }
        reconcilePending(sessionId)
    }

    public func applySseBatch(sessionId: String, event: SseBatchEvent) {
        touch(sessionId)
        merge(event.entries, into: sessionId)
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
