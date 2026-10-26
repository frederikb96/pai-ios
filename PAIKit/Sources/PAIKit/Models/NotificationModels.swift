import Foundation

/// Swift port of the notification contract — `pai-cloud/web/src/api/types.ts`'s `PaiNotification`,
/// `NotificationKind`, `NotificationsResponse` and `NotificationSummary` — read against what
/// `backend/src/pai_cloud/api.py`'s `_notification_to_dict` actually serialises, per this repo's
/// own rule that the backend, not `types.ts`, is the ground truth for a shape.
///
/// One log unifying two very different kinds of event: an agent calling
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
    /// The scheduled task whose run raised this. `nil` once that task is deleted (the name stays),
    /// and for alerts and ordinary sessions.
    public let taskId: String?
    public let taskName: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, title, body, anchor, alert
        case createdAt = "created_at"
        case readAt = "read_at"
        case sessionId = "session_id"
        case sessionTitle = "session_title"
        case taskId = "task_id"
        case taskName = "task_name"
    }

    public init(
        id: String, kind: PaiNotificationKind, title: String, body: String, createdAt: String, readAt: String?,
        sessionId: String?, sessionTitle: String?, anchor: PaiNotificationAnchor?, alert: PaiNotificationAlert?,
        taskId: String?, taskName: String?
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
        self.taskId = taskId
        self.taskName = taskName
    }

    /// The same row with a different read state or alert — the one place a row is rebuilt from
    /// itself, so a field added to the row cannot be dropped by a copy site.
    func with(readAt: String?, alert: PaiNotificationAlert?) -> PaiNotification {
        PaiNotification(
            id: id, kind: kind, title: title, body: body, createdAt: createdAt, readAt: readAt,
            sessionId: sessionId, sessionTitle: sessionTitle, anchor: anchor, alert: alert, taskId: taskId,
            taskName: taskName)
    }

    public var isUnread: Bool { readAt == nil }
}

/// Which notifications the feed keeps by origin: every one, only those a scheduled task's run
/// raised, or only the rest. `queryValue` is the `scheduled` query parameter, absent for `.any`.
public enum NotificationSource: String, CaseIterable, Sendable, Equatable {
    case any
    case scheduled
    case notScheduled

    public var title: String {
        switch self {
        case .any: "Any source"
        case .scheduled: "Scheduled"
        case .notScheduled: "Not scheduled"
        }
    }

    /// `nil` for `.any` — the backend's filter is "absent means all", not a third value to send.
    public var queryValue: String? {
        switch self {
        case .any: nil
        case .scheduled: "only"
        case .notScheduled: "exclude"
        }
    }

    /// The case a `scheduled` query value names; anything else is no filter.
    public init(queryValue: String?) {
        switch queryValue {
        case "only": self = .scheduled
        case "exclude": self = .notScheduled
        default: self = .any
        }
    }
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

// MARK: - Push channels

/// One channel a device can mute, as `GET /api/push/channels` serves it. The id is what a
/// registration's `muted_channels` holds; `kinds` are the notification kinds pushed on it. The
/// label and description are the server's, so a channel added there needs no client change.
public struct PushChannelInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let description: String
    public let kinds: [String]

    public init(id: String, label: String, description: String, kinds: [String]) {
        self.id = id
        self.label = label
        self.description = description
        self.kinds = kinds
    }
}

/// `GET /api/push/channels`.
public struct PushChannelsResponse: Codable, Sendable, Equatable {
    public let channels: [PushChannelInfo]

    public init(channels: [PushChannelInfo]) {
        self.channels = channels
    }
}
