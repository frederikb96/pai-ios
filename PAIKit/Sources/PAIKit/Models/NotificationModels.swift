import Foundation

/// Swift port of the notification contract — `pai-cloud/web/src/api/types.ts`'s `PaiNotification`,
/// `NotificationKind`, `NotificationsResponse` and `NotificationSummary` — read against what
/// `backend/src/pai_cloud/api.py`'s `_notification_to_dict` actually serialises, per this repo's
/// own rule that the backend, not `types.ts`, is the ground truth for a shape.
///
/// One log unifying two very different kinds of event (row 5.21): an agent calling
/// `notify`, and an alert transition. `alert` is non-nil only for `kind == .alert`; `sessionId`/
/// `sessionTitle`/`anchor` only ever populate for `kind == .agent`.

/// `"agent"` or `"alert"` on the wire — mirrors the backend's `PUSH_CHANNELS`.
public enum PaiNotificationKind: String, Codable, Sendable, Equatable, CaseIterable {
    case agent
    case alert
}

/// Where in the transcript an agent notification came from, once resolved.
///
/// A bare struct rather than folding `messageId` into `PaiNotification` directly: `nil` here
/// means "not resolvable, for any reason" (never resolved by the anchor window, the session or
/// the message since deleted, or simply not an agent notification) — every one of those reasons
/// collapses to the same client behaviour, opening the session at its normal restored position
/// with no jump and no highlight. There is deliberately no separate pending/resolved/unresolvable
/// state to read here: the backend never exposes one either, for the reason
/// `pai_cloud.notifications`'s module doc explains — a conclusion re-derived beside the fact it
/// describes drifts from it the moment the fact changes.
public struct PaiNotificationAnchor: Codable, Sendable, Equatable {
    public let messageId: Int

    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
    }

    public init(messageId: Int) {
        self.messageId = messageId
    }
}

/// The alert half of a notification row — present only for `kind == .alert`.
public struct PaiNotificationAlert: Codable, Sendable, Equatable {
    /// `nil` once the alert row itself is gone (cleared and later purged) — the notification
    /// stays as a historical record regardless, per this feature's whole reason for existing.
    public let id: String?
    public let key: String
    public let severity: String
    public let source: String
    /// `"raised"` or `"cleared"`.
    public let transition: String
    /// Derived by the backend from whether the alert row still exists uncleared — never computed
    /// client-side, since "active" is exactly the kind of fact two independent readers can drift
    /// apart on.
    public let active: Bool

    public init(id: String?, key: String, severity: String, source: String, transition: String, active: Bool) {
        self.id = id
        self.key = key
        self.severity = severity
        self.source = source
        self.transition = transition
        self.active = active
    }
}

/// One row in the feed — every alert transition and every agent-raised push, as a persistent log.
public struct PaiNotification: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: PaiNotificationKind
    public let title: String
    public let body: String
    public let createdAt: String
    public let readAt: String?
    /// Present for `kind == .agent` when the session that raised it still exists.
    public let sessionId: String?
    /// The session's title at read time, so a row needs no second fetch to show it.
    public let sessionTitle: String?
    public let anchor: PaiNotificationAnchor?
    public let alert: PaiNotificationAlert?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, anchor, alert
        case createdAt = "created_at"
        case readAt = "read_at"
        case sessionId = "session_id"
        case sessionTitle = "session_title"
    }

    public init(
        id: String, kind: PaiNotificationKind, title: String, body: String, createdAt: String, readAt: String?,
        sessionId: String?, sessionTitle: String?, anchor: PaiNotificationAnchor?, alert: PaiNotificationAlert?
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.readAt = readAt
        self.sessionId = sessionId
        self.sessionTitle = sessionTitle
        self.anchor = anchor
        self.alert = alert
    }

    public var isUnread: Bool { readAt == nil }
}

/// `GET /api/notifications`.
public struct NotificationsResponse: Codable, Sendable, Equatable {
    public let unread: Int
    public let hasMore: Bool
    public let notifications: [PaiNotification]

    enum CodingKeys: String, CodingKey {
        case unread, notifications
        case hasMore = "has_more"
    }

    public init(unread: Int, hasMore: Bool, notifications: [PaiNotification]) {
        self.unread = unread
        self.hasMore = hasMore
        self.notifications = notifications
    }
}

/// `GET /api/notifications/summary` — the cheap reconciliation fetch a badge renders from
/// without opening the centre.
public struct NotificationSummary: Codable, Sendable, Equatable {
    public let unread: Int
    public let latestId: String?

    enum CodingKeys: String, CodingKey {
        case unread
        case latestId = "latest_id"
    }

    public init(unread: Int, latestId: String?) {
        self.unread = unread
        self.latestId = latestId
    }
}
