import PAIKit
import SwiftUI

/// The notification centre (row 5.27): every alert transition and every agent push, newest
/// first, filterable, with unread state and mark-all-read. A plain `List` rather than the
/// transcript's `UICollectionView` — rows here are clamped to two lines of body text, so per the
/// `scrolling` skill's own "before writing any of it" checklist this needs no virtualization or
/// measurement machinery, and `List` gives swipe actions for free besides.
struct NotificationCenterScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotificationCenterStore.self) private var store

    /// Guards against a second `loadInitialNotifications()` on return from a pushed session —
    /// that call replaces `rows` wholesale, which would silently discard the scroll position
    /// `NavigationStack` would otherwise restore for free. Mirrors `SessionListView`'s own guard
    /// verbatim, per row 5.27 note 6.
    @State private var hasLoadedInitialNotifications = false
    /// Which alert row, if any, is expanded in place. A tap on a session row navigates instead —
    /// see `open(_:)` — so only one of these can ever be non-nil-equivalent per screen.
    @State private var expandedAlertID: String?

    var body: some View {
        list
            .paiScreenBackground()
            .navigationTitle("Notifications")
            .accessibilityIdentifier("notification-center")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Mark all read") {
                        Task { await store.markAllRead() }
                    }
                    .disabled(store.unread == 0)
                    .accessibilityIdentifier("notifications-mark-all-read")
                }
            }
            .task {
                guard !hasLoadedInitialNotifications else { return }
                await store.loadInitialNotifications()
                hasLoadedInitialNotifications = true
                await expandPendingFocusIfAny()
            }
            // A push tapped while the centre is already on top never runs the `.task` above
            // again — that only fires once, on first mount — so without this the new
            // `pendingFocusID` sits unconsumed until the screen is torn down and rebuilt, and
            // then expands whatever was still pending rather than nothing.
            .onChange(of: store.pendingFocusID) { _, focusID in
                guard focusID != nil else { return }
                Task { await expandPendingFocusIfAny() }
            }
    }

    // MARK: - List

    private var list: some View {
        List {
            filterRow
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.loadInitialNotifications() }
    }

    /// All / Sessions / Alerts, in the sticky first row rather than a nav-bar accessory — the
    /// same placement the web's own three-segment control takes in its sticky header.
    private var filterRow: some View {
        Picker("Filter", selection: filterBinding) {
            ForEach(NotificationFilter.allCases, id: \.self) { filter in
                Text(filter.title).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .accessibilityIdentifier("notification-filter")
    }

    private var filterBinding: Binding<NotificationFilter> {
        Binding(get: { store.filter }, set: { newValue in Task { await store.setFilter(newValue) } })
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoadedInitialNotifications {
            centeredRow { ProgressView() }
        } else if let error = store.loadError, store.rows.isEmpty {
            centeredRow {
                ContentUnavailableView {
                    Label("Couldn't load notifications", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                }
            }
            .accessibilityIdentifier("notifications-load-error")
        } else if store.rows.isEmpty {
            centeredRow {
                ContentUnavailableView(
                    "No notifications yet", systemImage: "bell",
                    description: Text("Alerts and messages from your sessions will appear here."))
            }
        } else {
            ForEach(store.rows) { notification in
                NotificationRowView(
                    notification: notification, isExpanded: expandedAlertID == notification.id,
                    onTap: { Task { await open(notification) } },
                    onClearAlert: { await clearAlert(notification) }
                )
                // Leading, not trailing — matching `SessionListView`'s own reasoning for why
                // Delete sits behind a sheet rather than a swipe: the destructive direction stays
                // out of reach of a thumb scrolling past. There is no destructive action here at
                // all (row 5.27 note 5 — no delete, this is a log), so the one swipe action that
                // exists gets the safer edge.
                .swipeActions(edge: .leading) {
                    if notification.isUnread {
                        Button {
                            Task { await store.markRead(notification.id) }
                        } label: {
                            Label("Mark read", systemImage: "checkmark.circle")
                        }
                        .tint(PaiPalette.primary500)
                    }
                }
                .onAppear {
                    guard store.hasMoreRows, !store.isLoadingMoreRows, notification.id == store.rows.last?.id
                    else { return }
                    Task { await store.loadMoreRows() }
                }
            }
            if store.isLoadingMoreRows {
                centeredRow { ProgressView() }
            }
        }
    }

    // MARK: - Actions

    /// A session row marks itself read and navigates; an alert row marks itself read and expands
    /// in place, leaving every other row untouched (row 5.28 note 3) — no navigation, so the
    /// unread state of the rest of the feed is simply whatever it already was.
    private func open(_ notification: PaiNotification) async {
        await store.markRead(notification.id)
        switch notification.kind {
        case .agent:
            // No session to open — it was deleted since the notification was raised. Marking it
            // read is still the right outcome; there is nowhere further to send the reader.
            guard let sessionId = notification.sessionId else { return }
            // Pushed, not replaced: the centre is already on the stack, so this alone gives Back
            // the "return to the list at the position it was left" behaviour row 5.27 asks for —
            // no extra bookkeeping needed the way a cold push (`RootView`) does need.
            environment.router.push(.session(id: sessionId, messageID: notification.anchor?.messageId))
        case .alert:
            expandedAlertID = (expandedAlertID == notification.id) ? nil : notification.id
        }
    }

    private func clearAlert(_ notification: PaiNotification) async {
        await store.clearAlert(notification.id)
    }

    /// A push notification or an in-app tap can ask the centre to land on one row the moment it
    /// opens — see `NotificationCenterStore.focus(id:)`. Only ever set for an alert (a session
    /// notification is resolved straight to its session and never routes through this screen at
    /// all — see `RootView.resolveAndOpenNotification`), so this only ever expands, never
    /// navigates again.
    ///
    /// `ensureLoaded` splices the row in if it fell outside the loaded page — an old alert, most
    /// likely — so it is expandable at all rather than silently un-expandable because it was
    /// never fetched.
    private func expandPendingFocusIfAny() async {
        guard let focusID = store.consumePendingFocus() else { return }
        await store.ensureLoaded(id: focusID)
        expandedAlertID = focusID
    }

    private func centeredRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
            Spacer()
        }
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}
