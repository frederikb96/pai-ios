import PAIKit
import SwiftUI
import UserNotifications

/// The app's outermost screen: the gate, and the navigation stack behind it.
struct RootView: View {
    @State private var environment = AppEnvironment()
    /// Whatever `CrashReporter` captured before this launch, if any — read once on appear rather
    /// than continuously, since nothing after launch can change what already happened before it.
    @State private var pendingCrash: CrashRecord?

    /// The parked deep link, if one is waiting. Read through the observable inbox rather than
    /// polled, so a notification tapped while the app is already open navigates immediately
    /// rather than on whatever the next redraw happens to be.
    private var deepLinks: DeepLinkInbox { DeepLinkInbox.shared }

    var body: some View {
        content
            .preferredColorScheme(colorScheme)
            .task(id: environment.connection == nil) {
                await environment.loadStartupState()
                // Concurrent, not sequential: `pollMachines()` never returns on its own (it loops
                // until the task is cancelled), so chaining a second poll after it would simply
                // never run.
                async let machinePoll: Void = environment.pollMachines()
                async let notificationPoll: Void = environment.pollNotificationSummary()
                _ = await (machinePoll, notificationPoll)
            }
            .onAppear { pendingCrash = CrashReporter.readLast() }
            // Two triggers, because a link and a usable app arrive in either order: tapped while
            // the app is open, the link is last; tapped from cold, the gate opening is last.
            .onChange(of: deepLinks.pending) { _, _ in consumeDeepLink() }
            .onChange(of: environment.router.gate) { _, _ in consumeDeepLink() }
            // The URL half — a shortcut or widget that opens the app by URL rather than through
            // an App Intent. Parked through the same inbox so there is one path to a screen from
            // outside, not two that can disagree.
            .onOpenURL { url in
                guard let link = DeepLink.from(url: url) else { return }
                deepLinks.receive(link)
            }
            // No `onDismiss` clear here on purpose: this is the only capture of the reason string
            // and full symbol list Apple's own crash report leaves out for this exception class,
            // and deleting it the moment the sheet closes destroys that evidence before anyone can
            // pull it off the device. It survives until explicitly acknowledged through the debug
            // bridge's `POST /crash/clear` — see `PAIApp.swift`'s `DebugRoutes`.
            .sheet(item: $pendingCrash) { crash in
                CrashReportSheet(record: crash)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch environment.router.gate {
        case .needsConfiguration:
            SignInView(environment: environment, reason: .firstLaunch)
        case .tokenRejected:
            SignInView(environment: environment, reason: .rejected(environment.lastAuthFailure))
        case .ready:
            if let connection = environment.connection {
                ZStack(alignment: .bottom) {
                    NavigationStack(path: navigationPath) {
                        SessionListView()
                            .navigationDestination(for: Route.self) { route in
                                destination(for: route)
                            }
                    }
                    // A block above the stack's own content, pushing it down rather than
                    // floating over it — the same "above the whole app" placement the web gives
                    // it, so it reads on the session list and inside an open conversation alike.
                    // Decorates the `NavigationStack` itself, which stays one view instance across
                    // every push, so the inset persists regardless of what the stack shows.
                    .safeAreaInset(edge: .top, spacing: 0) {
                        ClaudeAuthBanner()
                    }
                    ToastOverlay(toasts: connection.toasts)
                }
                // The one page ground for every screen the stack pushes — none of them paint
                // their own, so this is what stops each one falling through to pure black. See
                // `paiScreenBackground()`'s own doc comment for why that step matters.
                .paiScreenBackground()
                .environment(environment)
                .environment(connection.sessions)
                .environment(connection.machines)
                .environment(connection.claudeAuth)
                .environment(connection.transcript)
                .environment(connection.settings)
                .environment(connection.drafts)
                .environment(connection.me)
                .environment(connection.toasts)
                .environment(connection.notes)
                .environment(connection.notesBrowse)
                .environment(connection.staging)
                .environment(connection.notifications)
                // Only settles a token the backend has not seen yet — silent, and a no-op in the
                // common case. Asking for permission is deliberately NOT here: the system prompt
                // appears at most once per install and never again, so spending it the instant
                // the app opens, over whatever screen happens to be in front of the person, is
                // the worst possible moment. It lives behind an explicit control in Settings.
                .task {
                    // 🚨 Both halves, every launch, and the order matters less than the fact that
                    // the first one happens at all. Apple's contract is that an app asks for a
                    // token on every launch, because a token is not permanent — a restore from
                    // backup or an OS-level rotation issues a new one and silently invalidates
                    // the old. Asking only from the Settings button would mean never asking
                    // again after the first grant, since that button is shown only while the
                    // permission is still unanswered. Push would then go quiet with the app
                    // still reporting notifications as on, which is the worst way to fail.
                    await PushRegistrar.registerForRemoteNotificationsIfAuthorized(store: connection.push)
                    await connection.push.registerWithBackendIfNeeded()
                }
                .environment(\.terminalStreamClientFactory) { sessionID, callbacks in
                    PaiTerminalStreamClient(
                        sessionId: sessionID,
                        requestFactory: connection.requestFactory,
                        callbacks: callbacks
                    )
                }
                // Mirrors the unread count into the springboard badge (row 5.27 note 7) — the
                // half `aps.badge` cannot cover, since that only ever updates the badge when a
                // push actually arrives, not when a swipe or a mark-all-read changes the count
                // from inside the running app.
                .onChange(of: connection.notifications.unread) { _, unread in
                    UNUserNotificationCenter.current().setBadgeCount(unread)
                }
            } else {
                // `ready` without a connection should be unreachable; showing sign-in is the only
                // state a user can act on, and a blank screen is the alternative.
                SignInView(environment: environment, reason: .firstLaunch)
            }
        }
    }

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .session(let id, let messageID):
            SessionDetailView(sessionID: id, initialJumpMessageID: messageID)
        case .terminal(let sessionID):
            TerminalScreen(sessionID: sessionID)
        case .settings:
            SettingsScreen()
        case .createSession:
            CreateSessionRouteScreen()
        case .subagents(let parentID):
            SubagentListScreen(parentSessionId: parentID)
        case .notes:
            NoteListScreen()
        case .note(let id):
            NoteEditorScreen(noteID: id)
        case .noteContainers:
            NoteContainersScreen()
        case .notePreview(let id):
            NoteEditorScreen(noteID: id, startsInPreview: true)
        case .notifications:
            NotificationCenterScreen()
        case .recordings:
            RecordingsRouteScreen()
        }
    }

    /// Act on a parked deep link, but only once there is a signed-in app to act on it in.
    ///
    /// Left in the inbox otherwise rather than dropped: a notification tapped from cold arrives
    /// well before the token has been read and the connection built, and discarding it there is
    /// exactly the case this whole mechanism exists for.
    private func consumeDeepLink() {
        guard environment.router.gate == .ready, let connection = environment.connection else { return }
        guard let link = deepLinks.consume() else { return }
        // `.notification` is the one case `DeepLink.routes` cannot answer on its own — see its
        // doc comment. Resolving it needs a network round trip, so it gets its own path instead
        // of the synchronous `replace(with: link.routes)` every other case uses.
        if case .notification(let id) = link {
            Task { await resolveAndOpenNotification(id: id, connection: connection) }
            return
        }
        environment.router.replace(with: link.routes)
    }

    /// What a tapped push notification does once the app can act on it (row 5.28). The payload
    /// only ever carries the notification's own id — the anchor is not resolved at send time —
    /// so this fetches it fresh and routes on what comes back, rather than trusting anything
    /// stale the push itself might have carried.
    ///
    /// Always replaces the whole stack: a cold push arrives knowing nothing about what the app
    /// was showing (`Route.session`'s own doc comment), which is also right for a push tapped
    /// while the app happens to be open — that is a different action from an in-app tap on a row
    /// inside the centre, which `NotificationCenterScreen.open(_:)` handles by pushing instead,
    /// so Back there returns to the list rather than wherever the reader was before the push.
    private func resolveAndOpenNotification(id: String, connection: AppEnvironment.Connection) async {
        guard let notification = try? await connection.apiClient.getNotification(id: id) else {
            environment.router.replace(with: [.notifications])
            return
        }
        await connection.notifications.markRead(id)
        switch notification.kind {
        case .alert:
            environment.router.replace(with: [.notifications])
            connection.notifications.focus(id: notification.id)
        case .agent:
            guard let sessionId = notification.sessionId else {
                // The session is gone — nowhere to land. The centre is the honest fallback: the
                // notification is real and now marked read, there is simply no transcript left
                // to show for it.
                environment.router.replace(with: [.notifications])
                return
            }
            environment.router.replace(with: [.session(id: sessionId, messageID: notification.anchor?.messageId)])
        }
    }

    /// `nil` is "follow the system", which is what an absent override means to SwiftUI too.
    private var colorScheme: ColorScheme? {
        switch environment.connection?.settings.theme ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private var navigationPath: Binding<[Route]> {
        Binding(
            get: { environment.router.path },
            set: { environment.router.replace(with: $0) }
        )
    }
}

/// What `.createSession` pushes to — reproduces the real presentation (a sheet from the session
/// list) rather than pushing `CreateSessionView` directly, so the fixture screenshot workflow
/// photographs the exact thing Freddy sees rather than that view's own `NavigationStack` nested
/// inside this one with different, misleading chrome. See `Route.createSession`'s doc comment.
///
/// A home-screen shortcut reaches this same route (`DeepLink.createSession`), where — unlike the
/// fixture workflow — nothing else pops it back off: popping itself the moment its own sheet is
/// dismissed is what stops Cancel from leaving Freddy on a blank, transparent screen with a stray
/// system Back button.
private struct CreateSessionRouteScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                CreateSessionView()
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.pop()
            }
    }
}

/// What `.recordings` pushes to — reproduces the sheet the composer's plus-icon actually
/// presents, since `RecordingsSheet` has no screen of its own to navigate to. See
/// `Route.recordings`'s doc comment for why this route exists at all; shaped exactly like
/// `CreateSessionRouteScreen` above, for the same reason.
private struct RecordingsRouteScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                if let voice = environment.connection?.voice {
                    RecordingsSheet(
                        controller: voice,
                        onInsertTranscript: { _ in },
                        onAttach: { _ in }
                    )
                }
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.pop()
            }
    }
}
