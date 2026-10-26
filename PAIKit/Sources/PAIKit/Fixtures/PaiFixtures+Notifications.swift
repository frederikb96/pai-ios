import Foundation

/// The notification centre's corpus: two scheduled-task notifications (an unread blocking one,
/// which a task pushes, and a quiet one stored already read, which it does not); one unread agent
/// notification anchored to a real message in `PaiFixtures.transcript` — `9003`, an assistant
/// row — so a screenshot run can exercise the jump end to end; one unresolvable agent
/// notification (no session, no anchor — the graceful "open normally, no jump" degrade); one
/// unread alert still active; and one read alert already resolved. Between them this covers
/// every branch `NotificationRowView` draws differently: the unread dot, both severities'
/// colouring, the "jump to message" affordance appearing only when an anchor exists, and an
/// alert's active/resolved footer text.
extension PaiFixtures {

    /// `GET /api/notifications` as the backend answers it for the `kind` and `scheduled` query
    /// parameters: the corpus filtered the way the server filters it. `unread` stays the account's
    /// total, as on the wire.
    public static func notificationsPage(kind: String?, scheduled: String?) -> Data {
        guard var page = (try? JSONSerialization.jsonObject(with: data(notifications))) as? [String: Any],
            let rows = page["notifications"] as? [[String: Any]]
        else { return data(notifications) }
        page["notifications"] = rows.filter { row in
            if let kind, row["kind"] as? String != kind { return false }
            let fromTask = !(row["task_name"] is NSNull)
            switch scheduled {
            case "only": return fromTask
            case "exclude": return !fromTask
            default: return true
            }
        }
        return (try? JSONSerialization.data(withJSONObject: page)) ?? data(notifications)
    }

    public static let notifications = #"""
        {
          "unread": 3,
          "has_more": false,
          "notifications": [
            {
              "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d01",
              "kind": "agent",
              "title": "Deploy finished",
              "body": "v2.63.0 is live; health answers 200. Two sessions carried over cleanly.",
              "created_at": "2026-08-31T22:30:00.000000+00:00",
              "read_at": null,
              "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
              "session_title": "Cluster upgrade",
              "anchor": {"message_id": 9003},
              "alert": null,
              "task_id": null,
              "task_name": null
            },
            {
              "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d05",
              "kind": "agent",
              "title": "❌ Nightly backup stopped",
              "body": "The borg repository refused the lock; nothing was written tonight.",
              "created_at": "2026-08-31T22:10:00.000000+00:00",
              "read_at": null,
              "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
              "session_title": "Nightly backup",
              "anchor": null,
              "alert": null,
              "task_id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f60",
              "task_name": "Nightly backup"
            },
            {
              "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d02",
              "kind": "alert",
              "title": "Alert raised: health:agent",
              "body": "The VM agent has not reported in 6 minutes.",
              "created_at": "2026-08-31T18:04:00.000000+00:00",
              "read_at": null,
              "session_id": null,
              "session_title": null,
              "anchor": null,
              "alert": {
                "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918d10", "key": "health:agent", "severity": "error",
                "source": "health", "transition": "raised", "active": true
              },
              "task_id": null,
              "task_name": null
            },
            {
              "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d06",
              "kind": "agent",
              "title": "Grocery sync finished",
              "body": "Synced 42 items; nothing needs you.",
              "created_at": "2026-08-31T05:00:00.000000+00:00",
              "read_at": "2026-08-31T05:00:00.000000+00:00",
              "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
              "session_title": "Grocery sync",
              "anchor": null,
              "alert": null,
              "task_id": "5c0d8e21-7a64-4f0b-9d0e-1b2c3d4e5f61",
              "task_name": "Grocery sync"
            },
            {
              "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d03",
              "kind": "agent",
              "title": "Needs you",
              "body": "Waiting on a choice before it can continue.",
              "created_at": "2026-08-30T09:12:00.000000+00:00",
              "read_at": "2026-08-30T09:20:00.000000+00:00",
              "session_id": null,
              "session_title": null,
              "anchor": null,
              "alert": null,
              "task_id": null,
              "task_name": null
            },
            {
              "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d04",
              "kind": "alert",
              "title": "Alert resolved: health:agent",
              "body": "The VM agent is reporting again.",
              "created_at": "2026-08-29T07:00:00.000000+00:00",
              "read_at": "2026-08-29T07:05:00.000000+00:00",
              "session_id": null,
              "session_title": null,
              "anchor": null,
              "alert": {
                "id": null, "key": "health:agent", "severity": "error", "source": "health",
                "transition": "cleared", "active": false
              },
              "task_id": null,
              "task_name": null
            }
          ]
        }
        """#

    /// `GET /api/notifications/{id}` answers with one bare row, not the list wrapper — this is
    /// the same object as `notifications`'s first entry, kept separate because the two routes
    /// genuinely decode into different shapes (`PaiNotification` vs `NotificationsResponse`).
    public static let notificationDetail = #"""
        {
          "id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d01",
          "kind": "agent",
          "title": "Deploy finished",
          "body": "v2.63.0 is live; health answers 200. Two sessions carried over cleanly.",
          "created_at": "2026-08-31T22:30:00.000000+00:00",
          "read_at": null,
          "session_id": "305df4d3-1554-4fc3-be04-39a354a9e619",
          "session_title": "Cluster upgrade",
          "anchor": {"message_id": 9003},
          "alert": null,
          "task_id": null,
          "task_name": null
        }
        """#

    public static let notificationsSummary = #"""
        {"unread": 3, "latest_id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d01"}
        """#

    public static let notificationsMarked = #"""
        {"marked": 0}
        """#

    /// Real wire shape: six-digit fractions and a numeric offset, `details` either an object or null.
    public static let alerts = #"""
        {
          "total": 2,
          "alerts": [
            {
              "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918e01",
              "source": "agent", "key": "agent:vm:backup_notify_Grocery_Sync", "severity": "critical",
              "message": "Grocery sync failing - 3 runs in a row: unknown certificate verification error",
              "details": {"runs": 3},
              "count": 2,
              "created_at": "2026-10-01T08:22:54.123456+00:00",
              "last_seen_at": "2026-10-01T09:07:54.654321+00:00"
            },
            {
              "id": "a1b2c3d4-0000-4c1a-8f30-2b7e5c918e02",
              "source": "pipeline", "key": "embedding:qwen", "severity": "warning",
              "message": "An embedding call to qwen failed: timeout",
              "details": null,
              "count": 1,
              "created_at": "2026-10-03T12:00:00.000001+00:00",
              "last_seen_at": "2026-10-03T12:00:00.000001+00:00"
            }
          ]
        }
        """#

    public static let alertsCleared = #"""
        {"cleared": 0}
        """#
}
