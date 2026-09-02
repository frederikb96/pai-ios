import Foundation

/// The notification centre's corpus (row 5.27/5.28 in the pai-cloud spec): one unread agent
/// notification anchored to a real message in `PaiFixtures.transcript` — `9003`, an assistant
/// row — so a screenshot run can exercise the jump end to end; one unresolvable agent
/// notification (no session, no anchor — the graceful "open normally, no jump" degrade); one
/// unread alert still active; and one read alert already resolved. Between them this covers
/// every branch `NotificationRowView` draws differently: the unread dot, both severities'
/// colouring, the "jump to message" affordance appearing only when an anchor exists, and an
/// alert's active/resolved footer text.
extension PaiFixtures {

    public static let notifications = #"""
        {
          "unread": 2,
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
              "alert": null
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
              }
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
              "alert": null
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
              }
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
          "alert": null
        }
        """#

    public static let notificationsSummary = #"""
        {"unread": 2, "latest_id": "n1a2b3c4-0000-4c1a-8f30-2b7e5c918d01"}
        """#

    public static let notificationsMarked = #"""
        {"marked": 0}
        """#

    public static let alertsCleared = #"""
        {"cleared": 0}
        """#
}
