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
