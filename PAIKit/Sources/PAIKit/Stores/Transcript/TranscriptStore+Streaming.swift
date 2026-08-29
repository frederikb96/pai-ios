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
        if let tokens = event.sessionTokens { sessionTokens[sessionId] = tokens }
        reconcilePending(sessionId)
    }

    /// The `status` event's `pending_sends`/`last_error` pair, plus the derived "is a turn
    /// running" flag the transcript uses for its own loading indicator.
    ///
    /// Session-level fields on the same event (`state`, `blocker`, `working`) belong to whichever
    /// store owns session state — this only reads the two fields that decide what the transcript
    /// itself shows.
    public func applySseStatus(sessionId: String, event: SseStatusEvent) {
        setDelivery(sessionId: sessionId, pendingSends: event.pendingSends ?? [], lastError: event.lastError)
        isProcessing = event.status == .pending || event.status == .active
    }

    public func setSseConnected(_ connected: Bool) {
        sseConnected = connected
    }
}
