import Foundation

/// A message and the distance from the top of the viewport to the top of its row, in points.
public struct TranscriptRowPosition: Equatable, Sendable {
    public let messageId: Int
    public let offset: Double

    public init(messageId: Int, offset: Double) {
        self.messageId = messageId
        self.offset = offset
    }
}

/// The top-visible row, recorded continuously while scrolling — identity, never a pixel offset,
/// so it survives across a session's messages being re-fetched or re-laid-out.
public struct TranscriptAnchor: Equatable, Sendable {
    public let messageId: Int
    /// Distance from the top of the viewport to the top of this row, in points.
    public let offset: Double
    /// Set only when this position was at the live edge: the newest message on screen. Coming
    /// back lands on it rather than at the bottom, so whatever arrived while the reader was away
    /// sits below it, unread, instead of having been scrolled past on their behalf.
    ///
    /// "At the live edge" is computed fresh from geometry at record time, deliberately
    /// independent of ``EdgeFollowLatch/isPinned``. That flag answers a different, sticky question
    /// ("should new output keep auto-following right now?"); a restore has no such history to
    /// protect, and a reader who scrolls down to the last message by hand essentially never lands
    /// within the latch's re-pin distance of the literal end — so the two questions need
    /// different answers even though both describe "at the bottom".
    public let lastSeen: TranscriptRowPosition?

    public init(messageId: Int, offset: Double, lastSeen: TranscriptRowPosition? = nil) {
        self.messageId = messageId
        self.offset = offset
        self.lastSeen = lastSeen
    }
}

extension TranscriptAnchor {
    /// What to persist to the server for this anchor — the `PUT /api/session/{id}/read-position`
    /// body, before JSON encoding. Mirrors the web's own `readPositionPayload`: caught up sends
    /// the newest message the reader saw, which a return measures "arrived since" against.
    ///
    /// `hasNewer` is the loaded window's own flag (`TranscriptWindow.hasNewer`), read live by the
    /// caller rather than threaded through earlier — the debounce this feeds can fire well after
    /// the scroll that scheduled it, by which time the window's own `hasNewer` may have changed.
    /// While it is true, `lastSeen` cannot be trusted to mean "caught up": the bottom of a
    /// non-tail window is not the end of the conversation, whatever the geometry said when the
    /// anchor was recorded.
    public static func readPositionPayload(for anchor: TranscriptAnchor, hasNewer: Bool) -> (
        messageId: Int?, offsetPx: Int?, atBottom: Bool
    ) {
        if hasNewer { return (anchor.messageId, Int(anchor.offset.rounded()), false) }
        if let lastSeen = anchor.lastSeen {
            return (lastSeen.messageId, Int(lastSeen.offset.rounded()), true)
        }
        return (anchor.messageId, Int(anchor.offset.rounded()), false)
    }

    /// The anchor to seed a session's very first restore this process ever performs for it, from
    /// whatever the server was last told (`Session.readPosition*`) — `nil` when there is nothing
    /// to seed: no position has ever been recorded, or one at the live edge from a client that
    /// records no message there, which `TranscriptRestore.target` already falls back to the
    /// bottom for.
    /// The anchor an open starts from: the one this process remembers, unless the server holds a
    /// position saved later than this process's own last acknowledged save — another device, or
    /// the web, has read further since. Both times are the server's clock, so devices whose clocks
    /// disagree still order correctly. Returns the save time to remember alongside the anchor.
    public static func seed(
        current: TranscriptAnchor?, persisted: PersistedReadPosition?, lastOwnSave: Date?
    ) -> (anchor: TranscriptAnchor?, lastOwnSave: Date?) {
        guard let persisted else { return (current, lastOwnSave) }
        let savedElsewhereSince: Bool
        if let savedAt = persisted.savedAt {
            savedElsewhereSince = lastOwnSave.map { savedAt > $0 } ?? true
        } else {
            savedElsewhereSince = false
        }
        guard current == nil || savedElsewhereSince else { return (current, lastOwnSave) }
        return (fromPersisted(persisted), persisted.savedAt ?? lastOwnSave)
    }

    public static func fromPersisted(_ persisted: PersistedReadPosition?) -> TranscriptAnchor? {
        guard let persisted, let messageId = persisted.messageId, let offsetPx = persisted.offsetPx
        else { return nil }
        let position = TranscriptRowPosition(messageId: messageId, offset: Double(offsetPx))
        return TranscriptAnchor(
            messageId: messageId, offset: position.offset, lastSeen: persisted.atBottom ? position : nil)
    }
}

/// A session's read position as last persisted server-side, decoded off `Session` — the source
/// `TranscriptAnchor.fromPersisted(_:)` seeds a fresh restore from.
public struct PersistedReadPosition: Equatable, Sendable {
    public let messageId: Int?
    public let offsetPx: Int?
    public let atBottom: Bool
    /// The server's time for the save; `nil` for one saved before it recorded that.
    public let savedAt: Date?

    public init(messageId: Int?, offsetPx: Int?, atBottom: Bool, savedAt: Date? = nil) {
        self.messageId = messageId
        self.offsetPx = offsetPx
        self.atBottom = atBottom
        self.savedAt = savedAt
    }
}

public enum TranscriptRestoreTarget: Equatable, Sendable {
    case bottom
    case message(id: Int)
    /// A position left at the live edge with messages arrived since: the last message seen, its
    /// end at the bottom of the viewport and the new ones below it, following off.
    case lastSeen(id: Int)
    /// A deep link's target, already located into the window — landed the way a search hit is,
    /// with a lead above it and the ring, rather than flush at the top the way a read position is.
    /// Never produced by ``TranscriptRestore/target(for:loadedMessageIds:)``; see
    /// `TranscriptStore.deepLinkLanding(for:sessionId:fetchAround:)`.
    case deepLink(id: Int)
}

/// Where a session switch (or a remount of the scroll surface on the same session) should land.
public enum TranscriptRestore {

    /// Resolves the last recorded anchor against the window the incoming session actually has
    /// loaded, falling back to the bottom whenever the anchor cannot be honoured — a row the LRU
    /// has since evicted — rather than guessing a nearby position. Predictable beats clever for a
    /// case this rare. A position left at the live edge with nothing newer loaded is the bottom
    /// too: the reader is back where they were, and following.
    public static func target(for anchor: TranscriptAnchor?, loadedMessageIds: some Sequence<Int>)
        -> TranscriptRestoreTarget
    {
        guard let anchor else { return .bottom }
        let loaded = Set(loadedMessageIds)
        if let lastSeen = anchor.lastSeen {
            guard loaded.contains(lastSeen.messageId), loaded.contains(where: { $0 > lastSeen.messageId })
            else { return .bottom }
            return .lastSeen(id: lastSeen.messageId)
        }
        guard loaded.contains(anchor.messageId) else { return .bottom }
        return .message(id: anchor.messageId)
    }
}
