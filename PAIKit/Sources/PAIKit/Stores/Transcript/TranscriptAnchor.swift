import Foundation

/// The top-visible row, recorded continuously while scrolling — identity, never a pixel offset,
/// so it survives across a session's messages being re-fetched or re-laid-out.
///
/// `atLiveEdge` is computed fresh from geometry at record time, deliberately independent of
/// ``EdgeFollowLatch/isPinned``. That flag answers a different, sticky question ("should new
/// output keep auto-following right now?"); a restore has no such history to protect, and a
/// reader who scrolls down to the last message by hand essentially never lands within the
/// latch's re-pin distance of the literal end — so the two questions need different answers even
/// though both describe "at the bottom".
public struct TranscriptAnchor: Equatable, Sendable {
    public let messageId: Int
    /// Distance from the top of the viewport to the top of this row, in points.
    public let offset: Double
    public let atLiveEdge: Bool

    public init(messageId: Int, offset: Double, atLiveEdge: Bool) {
        self.messageId = messageId
        self.offset = offset
        self.atLiveEdge = atLiveEdge
    }
}

extension TranscriptAnchor {
    /// What to persist to the server for this anchor — the `PUT /api/session/{id}/read-position`
    /// body, before JSON encoding. Mirrors the web's own `readPositionPayload`: caught up means
    /// nothing to pin a message at, since a stale id from a moment ago is worse than none — the
    /// reader has moved on from it.
    ///
    /// The web additionally gates this on whether the loaded window's own newest message is the
    /// session's newest (`hasNewer`) — a concept this app does not have yet (row 5.30's own note).
    /// Until it does, `atLiveEdge` alone decides `atBottom` here, same as it already decides
    /// everything else this anchor drives.
    public static func readPositionPayload(for anchor: TranscriptAnchor) -> (
        messageId: Int?, offsetPx: Int?, atBottom: Bool
    ) {
        if anchor.atLiveEdge { return (nil, nil, true) }
        return (anchor.messageId, Int(anchor.offset.rounded()), false)
    }

    /// The anchor to seed a session's very first restore this process ever performs for it, from
    /// whatever the server was last told (`Session.readPosition*`) — `nil` when there is nothing
    /// to seed: no position has ever been recorded, or the recorded one was already at the live
    /// edge, which `TranscriptRestore.target` already falls back to for a `nil` anchor.
    public static func fromPersisted(_ persisted: PersistedReadPosition?) -> TranscriptAnchor? {
        guard let persisted, !persisted.atBottom, let messageId = persisted.messageId,
            let offsetPx = persisted.offsetPx
        else { return nil }
        return TranscriptAnchor(messageId: messageId, offset: Double(offsetPx), atLiveEdge: false)
    }
}

/// A session's read position as last persisted server-side, decoded off `Session` — the source
/// `TranscriptAnchor.fromPersisted(_:)` seeds a fresh restore from.
public struct PersistedReadPosition: Equatable, Sendable {
    public let messageId: Int?
    public let offsetPx: Int?
    public let atBottom: Bool

    public init(messageId: Int?, offsetPx: Int?, atBottom: Bool) {
        self.messageId = messageId
        self.offsetPx = offsetPx
        self.atBottom = atBottom
    }
}

public enum TranscriptRestoreTarget: Equatable, Sendable {
    case bottom
    case message(id: Int)
}

/// Where a session switch (or a remount of the scroll surface on the same session) should land.
public enum TranscriptRestore {

    /// Resolves the last recorded anchor against the window the incoming session actually has
    /// loaded, falling back to the bottom whenever the anchor cannot be honoured — an anchor
    /// recorded at the live edge, or a row the LRU has since evicted — rather than guessing a
    /// nearby position. Predictable beats clever for a case this rare.
    public static func target(for anchor: TranscriptAnchor?, loadedMessageIds: some Sequence<Int>)
        -> TranscriptRestoreTarget
    {
        guard let anchor, !anchor.atLiveEdge else { return .bottom }
        guard Set(loadedMessageIds).contains(anchor.messageId) else { return .bottom }
        return .message(id: anchor.messageId)
    }
}
