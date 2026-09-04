import Foundation

/// Swift port of `pai-cloud/web/src/api/types.ts` (the "SSE Events" / "Terminal streaming"
/// sections). Payload shapes only — the connection/reconnect/cursor logic that decodes these
/// lives in `PaiSseClient` and `PaiTerminalStreamClient`.

public struct SseInitEvent: Codable, Sendable, Equatable {
    public let entries: [Message]
    public let cursor: Int?
    public let hasMore: Bool
    public let sessionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case entries, cursor
        case hasMore = "has_more"
        case sessionTokens = "session_tokens"
    }

    public init(entries: [Message], cursor: Int?, hasMore: Bool, sessionTokens: Int?) {
        self.entries = entries
        self.cursor = cursor
        self.hasMore = hasMore
        self.sessionTokens = sessionTokens
    }
}

public struct SseBatchEvent: Codable, Sendable, Equatable {
    public let entries: [Message]
    public let sessionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case entries
        case sessionTokens = "session_tokens"
    }

    public init(entries: [Message], sessionTokens: Int?) {
        self.entries = entries
        self.sessionTokens = sessionTokens
    }
}

/// One send the server is still expecting a transcript entry for.
public struct PendingSend: Codable, Sendable, Equatable, Identifiable {
    /// The outgoing row's id, echoed by the entry that eventually confirms it — see
    /// `Message.outboxId`.
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

public struct SseStatusEvent: Codable, Sendable, Equatable {
    public let status: SessionStatus
    public let state: SessionState?
    public let blocker: Blocker?
    /// See `Session.working`.
    public let working: Bool?
    /// See `Session.presenceState`.
    public let presenceState: SessionPresenceState?
    /// See `Session.activityCounts`.
    public let activityCounts: ActivityCounts?
    /// Outgoing messages not yet delivered.
    ///
    /// ⚠️ Superseded by `pendingSends`, which the web client reads instead — nothing there
    /// consumes this pair. Kept for contract fidelity; a new caller should reach for
    /// `pendingSends`.
    public let queued: Int?
    /// Their text, oldest first. See the `queued` doc comment.
    public let queuedTexts: [String]?
    /// Every send with no transcript entry yet — queued and relayed alike. Server-derived, so
    /// it is the same on every device and survives a reload.
    public let pendingSends: [PendingSend]?
    /// Why the last delivery attempt failed, if one did.
    public let lastError: String?

    enum CodingKeys: String, CodingKey {
        case status, state, blocker, working, queued
        case presenceState = "presence_state"
        case activityCounts = "activity_counts"
        case queuedTexts = "queued_texts"
        case pendingSends = "pending_sends"
        case lastError = "last_error"
    }

    public init(
        status: SessionStatus,
        state: SessionState?,
        blocker: Blocker?,
        working: Bool?,
        presenceState: SessionPresenceState? = nil,
        activityCounts: ActivityCounts? = nil,
        queued: Int?,
        queuedTexts: [String]?,
        pendingSends: [PendingSend]?,
        lastError: String?
    ) {
        self.status = status
        self.state = state
        self.blocker = blocker
        self.working = working
        self.presenceState = presenceState
        self.activityCounts = activityCounts
        self.queued = queued
        self.queuedTexts = queuedTexts
        self.pendingSends = pendingSends
        self.lastError = lastError
    }
}

public struct SseProcessingEvent: Codable, Sendable, Equatable {
    public let processing: Bool
    public let elapsed: Double

    public init(processing: Bool, elapsed: Double) {
        self.processing = processing
        self.elapsed = elapsed
    }
}

/// `GET /api/notifications/stream`'s `notification` event — a new row plus the account's
/// freshly-counted unread total, ridden alongside so a client already showing the row (a push
/// banner, an open centre) never has to make a second request just to keep its badge in step.
public struct SseNotificationEvent: Codable, Sendable, Equatable {
    public let notification: PaiNotification
    public let unread: Int

    public init(notification: PaiNotification, unread: Int) {
        self.notification = notification
        self.unread = unread
    }
}

/// The same stream's `read` event — deliberately carries no row: a read change never touches
/// anything a client does not already hold, only the unread total moves. See
/// `PaiNotificationStreamClient`'s doc comment for who consumes this and why.
public struct SseNotificationReadEvent: Codable, Sendable, Equatable {
    public let unread: Int

    public init(unread: Int) {
        self.unread = unread
    }
}

/// The transcript stream's `arc` event — sent to every session bound to a spec after any write
/// to it. Carries the spec that changed and nothing else: the view re-reads what it needs over
/// `GET /api/arc/specs/{uuid}/recover`, so this can never be a second, staler copy of the spec.
public struct ArcSseEvent: Codable, Sendable, Equatable {
    public let specUuid: String

    enum CodingKeys: String, CodingKey {
        case specUuid = "spec_uuid"
    }

    public init(specUuid: String) {
        self.specUuid = specUuid
    }
}

/// Documented for parity with `types.ts`; the terminal stream itself decodes frames loosely
/// (see `PaiTerminalStreamClient`) rather than through this type, because a malformed or
/// non-JSON frame body is a normal case there, not a decode failure.
public struct TerminalFrameEvent: Codable, Sendable, Equatable {
    public let data: String

    /// False while the frame is anchored to a scrolled-back offset rather than following the
    /// live pane.
    ///
    /// Absent or malformed decodes as `true`, matching the web client. The safe failure mode is
    /// "assume live": a wrongly-shown "scrolled back" banner is one nothing can clear, while a
    /// wrongly-hidden one costs nothing.
    ///
    /// The backend sends this and `web/src/api/types.ts` does not declare it — the type
    /// undercounts the wire. Read `terminalStream.ts`, which parses it, rather than the interface.
    public let live: Bool

    public init(data: String, live: Bool = true) {
        self.data = data
        self.live = live
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        data = try container.decode(String.self, forKey: .data)
        // Absent *or malformed* means live. `decodeIfPresent` would throw on a present non-bool,
        // which loses the frame entirely — the web tolerates the same garbage for the same reason.
        live = (try? container.decode(Bool.self, forKey: .live)) ?? true
    }

    private enum CodingKeys: String, CodingKey {
        case data
        case live
    }
}
