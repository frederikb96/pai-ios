import Foundation
import Observation

/// Which segment of the feed is showing — mirrors the web's three-segment control (row 5.27's
/// verification: "the same filters and unread semantics as the web").
public enum NotificationFilter: String, CaseIterable, Sendable, Equatable {
    case all
    case agent
    case alert

    /// What the segmented control's label reads. "Sessions" rather than "Agent" — this is the
    /// word the rest of the app already uses for the same concept (`SessionListView`), and
    /// `agent` only ever names the wire's `kind` value.
    public var title: String {
        switch self {
        case .all: "All"
        case .agent: "Sessions"
        case .alert: "Alerts"
        }
    }

    /// `nil` for `.all` — the backend's own filter is "absent means every kind", not a third
    /// value to send.
    var kind: PaiNotificationKind? {
        switch self {
        case .all: nil
        case .agent: .agent
        case .alert: .alert
        }
    }
}

/// The narrow slice of `PaiApiClient` this store needs — see `/subagents`' guidance on declaring
/// a protocol per consumer rather than mirroring the whole client. `PaiApiClient` already
/// conforms structurally; the conformance is declared here, next to the protocol it satisfies.
public protocol NotificationCenterApiClient: Sendable {
    func getNotifications(
        limit: Int?, beforeId: String?, kind: PaiNotificationKind?
    ) async throws -> NotificationsResponse
    func getNotification(id: String) async throws -> PaiNotification
    func getNotificationsSummary() async throws -> NotificationSummary
    @discardableResult func markNotificationsRead(ids: [String]) async throws -> Int
    @discardableResult func markAllNotificationsRead() async throws -> Int
    @discardableResult func clearAlerts(ids: [String]) async throws -> Int
}

extension PaiApiClient: NotificationCenterApiClient {}

/// The notification centre's list, paging and unread state (row 5.27).
///
/// Owns exactly what the screen shows and the rules for changing it, per this package's own
/// layering — the view stays thin enough to need no unit test of its own. Paging is a plain
/// backward cursor by id, the same shape `SessionListStore` and `TranscriptWindow` both already
/// use for the same reason: rows can arrive between pages, so an offset would skip or repeat one.
///
/// Deliberately no "mark unread": the backend exposes only `POST /api/notifications/read`, on
/// purpose — this is a log ("I saw this"), not a mailbox with per-message state to toggle back.
@MainActor
@Observable
public final class NotificationCenterStore {
    private let api: NotificationCenterApiClient

    public private(set) var rows: [PaiNotification] = []
    /// The account-wide unread count. Kept fresh from whichever response last reported it — the
    /// list endpoint always answers with the current total, not a per-page figure, so a filtered
    /// view still shows the true badge count.
    public private(set) var unread: Int = 0
    public private(set) var hasMoreRows = false
    public private(set) var isLoadingMoreRows = false
    public private(set) var loadError: String?
    public private(set) var filter: NotificationFilter = .all

    /// A row's id, if a push or an in-app tap asked the screen to focus it the moment it opens —
    /// consumed by the screen (marking it read and, for an alert, expanding it), then cleared.
    /// Lives here rather than on `Router`, which stays agnostic of what a notification is.
    public private(set) var pendingFocusID: String?

    private static let pageLimit = 50

    public init(api: NotificationCenterApiClient) {
        self.api = api
    }

    /// The first page, replacing whatever was loaded. Call this on first entry and when the
    /// filter changes — never on every re-entry to the screen, which is what would discard a
    /// reader's scroll position; see `NotificationCenterScreen`'s own loaded-once guard, which
    /// mirrors `SessionListView`'s for the same reason (row 5.27 note 6).
    public func loadInitialNotifications() async {
        loadError = nil
        do {
            let response = try await api.getNotifications(limit: Self.pageLimit, beforeId: nil, kind: filter.kind)
            rows = response.notifications
            unread = response.unread
            hasMoreRows = response.hasMore
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Couldn't load notifications"
        }
    }

    public func setFilter(_ filter: NotificationFilter) async {
        guard filter != self.filter else { return }
        self.filter = filter
        await loadInitialNotifications()
    }

    public func loadMoreRows() async {
        guard hasMoreRows, !isLoadingMoreRows, let lastID = rows.last?.id else { return }
        isLoadingMoreRows = true
        defer { isLoadingMoreRows = false }
        do {
            let response = try await api.getNotifications(limit: Self.pageLimit, beforeId: lastID, kind: filter.kind)
            rows.append(contentsOf: response.notifications)
            unread = response.unread
            hasMoreRows = response.hasMore
        } catch {
            // Matches `SessionListStore`'s own paging failure: the first page already loaded is
            // still worth showing, so this fails silently rather than replacing it with an error.
            // Scrolling back near the top retries, the same recovery `checkOlderPageTrigger` gives
            // the transcript's own older-page load.
        }
    }

    /// The cheap reconciliation fetch — what a badge renders from without opening the centre, and
    /// what self-heals it after a push notification the app never actually shows a banner for
    /// (delivered while backgrounded, or muted). Touches only `unread`, never `rows`.
    public func refreshSummary() async {
        guard let summary = try? await api.getNotificationsSummary() else { return }
        unread = summary.unread
    }

    /// Marks one row read — the swipe action, and what a tap does before navigating. Optimistic
    /// and reverted on failure when the row is loaded locally; when it is not (a cold push tap
    /// resolves and opens a session directly, without ever visiting the centre — see
    /// `RootView.resolveAndOpenNotification`) this still tells the backend, just with nothing
    /// local to revert if it fails.
    public func markRead(_ id: String) async {
        guard let index = rows.firstIndex(where: { $0.id == id }) else {
            try? await api.markNotificationsRead(ids: [id])
            return
        }
        guard rows[index].isUnread else { return }
        let previous = rows[index]
        setReadAtNow(at: index)
        unread = max(0, unread - 1)
        do {
            try await api.markNotificationsRead(ids: [id])
        } catch {
            rows[index] = previous
            unread += 1
        }
    }

    public func markAllRead() async {
        let unreadIDs = rows.filter(\.isUnread).map(\.id)
        guard !unreadIDs.isEmpty || unread > 0 else { return }
        let previousRows = rows
        let previousUnread = unread
        for index in rows.indices where rows[index].isUnread {
            setReadAtNow(at: index)
        }
        unread = 0
        do {
            _ = try await api.markAllNotificationsRead()
        } catch {
            rows = previousRows
            unread = previousUnread
        }
    }

    /// Called once, when a push or an in-app tap names a specific row the screen should land on
    /// and mark read the moment it appears.
    public func focus(id: String) {
        pendingFocusID = id
    }

    public func consumePendingFocus() -> String? {
        defer { pendingFocusID = nil }
        return pendingFocusID
    }

    /// Fetches `id` on its own and prepends it to `rows` if it is not already loaded — what
    /// makes a focused row from an old push visible at all when it falls outside the first page,
    /// mirroring the web's own splice-in (`NotificationsApp.tsx`'s `expandedAlertId` effect).
    /// Prepending rather than inserting at its true chronological position is deliberate, not a
    /// shortcut: it is what puts the row near the top of the list without any scroll-to-focus
    /// machinery, the same reason the web never built one either. A no-op, not an error, if the
    /// row is gone or already present.
    public func ensureLoaded(id: String) async {
        guard !rows.contains(where: { $0.id == id }) else { return }
        guard let notification = try? await api.getNotification(id: id) else { return }
        rows.insert(notification, at: 0)
    }

    /// Marks one alert's transition inactive, in place — the row itself stays, since it is a
    /// historical record regardless of whether the alert is still active (see
    /// `PaiNotificationAlert.id`'s own doc comment), only `active` flips. Mirrors the web's own
    /// patch (`NotificationsApp.tsx`'s `handleClear`) rather than a full reload, which would
    /// discard scroll position and every page loaded past the first. Returns whether the clear
    /// actually reached the backend, so the caller can leave the button visible on failure.
    @discardableResult
    public func clearAlert(_ id: String) async -> Bool {
        guard let index = rows.firstIndex(where: { $0.id == id }), let alert = rows[index].alert,
            let alertId = alert.id
        else { return false }
        guard (try? await api.clearAlerts(ids: [alertId])) != nil else { return false }
        let row = rows[index]
        rows[index] = PaiNotification(
            id: row.id, kind: row.kind, title: row.title, body: row.body, createdAt: row.createdAt,
            readAt: row.readAt, sessionId: row.sessionId, sessionTitle: row.sessionTitle, anchor: row.anchor,
            alert: PaiNotificationAlert(
                id: alert.id, key: alert.key, severity: alert.severity, source: alert.source,
                transition: alert.transition, active: false)
        )
        return true
    }

    private func setReadAtNow(at index: Int) {
        let row = rows[index]
        rows[index] = PaiNotification(
            id: row.id, kind: row.kind, title: row.title, body: row.body, createdAt: row.createdAt,
            readAt: ISO8601DateFormatter().string(from: Date()), sessionId: row.sessionId,
            sessionTitle: row.sessionTitle, anchor: row.anchor, alert: row.alert
        )
    }
}
