import PAIKit
import SwiftUI
import UserNotifications

/// The app's outermost screen: the gate, and the navigation stack behind it.
struct RootView: View {
    @State private var environment = AppEnvironment()
    /// Whatever `CrashReporter` captured before this launch, if any — read once on appear rather
    /// than continuously, since nothing after launch can change what already happened before it.
    @State private var pendingCrash: CrashRecord?
    @Environment(\.scenePhase) private var scenePhase
    /// The account-wide notification stream (row 24.5) — live only while the phone is actually
    /// in front of the reader. Rebuilt on every foreground rather than reused across a
    /// background/foreground cycle: `PaiNotificationStreamClient.disconnect()` is a one-shot stop
    /// for the whole instance, matching `PaiSseClient`'s own lifetime, so "resume" here means a
    /// fresh client the same way opening a session again builds a fresh `PaiSseClient` rather
    /// than un-stopping the old one.
    @State private var notificationStream: PaiNotificationStreamClient?

    /// The parked deep link, if one is waiting. Read through the observable inbox rather than
    /// polled, so a notification tapped while the app is already open navigates immediately
    /// rather than on whatever the next redraw happens to be.
    private var deepLinks: DeepLinkInbox { DeepLinkInbox.shared }

    var body: some View {
        content
            .preferredColorScheme(colorScheme)
            .task(id: environment.connection == nil) {
                await environment.loadStartupState()
                // Set once, unconditionally, rather than left to the `.onChange` below — that
                // only fires on an actual change, so a badge APNs set while the app was
                // backgrounded and then cleared elsewhere (the web, another device) never gets a
                // change to react to here: the launch value and the freshly fetched true value
                // are both zero, and a badge stuck showing a stale count survives indefinitely.
                if let unread = environment.connection?.notifications.unread {
                    try? await UNUserNotificationCenter.current().setBadgeCount(unread)
                }
                // The delivered-notification half of the same self-heal (row 24.7): a banner
                // read from elsewhere while this app was not running yet has no earlier moment
                // to have been cleared at.
                if let connection = environment.connection {
                    await PushRegistrar.reconcileDeliveredNotifications(against: connection.notifications)
                    connectNotificationStream(connection)
                }
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
                    // Where a silent read-sync push (row 24.5/24.7) actually reaches app code —
                    // `PushRegistrar.application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`
                    // has no environment of its own to read `connection.notifications` from, since
                    // it can fire before this screen — or any screen — is on top. Set once here,
                    // the same way `PushRegistrar.store` is, and for the same reason.
                    PushRegistrar.notificationsStore = connection.notifications
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
                    Task { try? await UNUserNotificationCenter.current().setBadgeCount(unread) }
                }
                // The stream is only ever worth holding open while this screen is actually in
                // front of the reader — see `notificationStream`'s own doc comment for why
                // backgrounding tears it down rather than merely pausing it, and why the
                // foreground side rebuilds rather than resumes. `.inactive` (a brief transitional
                // state — the app switcher, an interruption) is deliberately not a disconnect
                // trigger: treating it as one would thrash the connection on every such transition
                // with no benefit, since the process keeps running throughout.
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        connectNotificationStream(connection)
                        Task {
                            await connection.notifications.refreshSummary()
                            await PushRegistrar.reconcileDeliveredNotifications(against: connection.notifications)
                        }
                    case .background:
                        notificationStream?.disconnect()
                        notificationStream = nil
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
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
            // Explicit identity, keyed on the session id alone (never `messageID` — see
            // `Route.session`'s own doc comment on why that stays out of equality). Without this,
            // `Router.replace(with:)` swapping a `.session(id: "A")` destination for a
            // `.session(id: "B")` one at the same stack depth can leave `NavigationStack` treating
            // it as the same destination updated in place rather than a new one pushed — a
            // documented `NavigationStack` bug when a path is replaced wholesale with a
            // same-length array whose values differ (Apple Feedback FB18336684). `SessionDetailView`
            // itself would still pick up the new title from its `sessionID` property either way,
            // since that part is plain SwiftUI state; what does not recover on its own is
            // `TranscriptCollectionView`'s `UIViewControllerRepresentable`, whose
            // `updateUIViewController` is deliberately a no-op (the controller is meant to be torn
            // down and rebuilt on every navigation into a session, never reconfigured for a new
            // one) — so a reused destination left session A's transcript view controller mounted
            // under session B's title. Forcing the identity here makes SwiftUI discard the whole
            // subtree and rebuild it, restoring "recreated on every navigation into a session" for
            // this path the same as an ordinary push already gets it for free.
            SessionDetailView(sessionID: id, initialJumpMessageID: messageID)
                .id(id)
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
            // Same reasoning and the same fix as `.session` above — `Router.openNote(id:)` is the
            // one path that replaces a `.note(id:)` destination for a *different* note at the same
            // stack depth (`replace(with: [.notes, .note(id: id)])`), reached from a deep link or a
            // home-screen shortcut. `MarkdownSourceTextView`'s own `updateUIView` is not a no-op —
            // unlike the transcript's, it genuinely detects and applies a changed `text` — so a
            // reused destination would still end up showing the right note body. What it would not
            // recover on its own is `NoteEditorScreen`'s own screen-level `@State`: `titleText` and
            // `isTitleFocused` in particular, which a reused identity carries over from the note
            // just left. The concrete failure that opens: mid-edit on note A's title when a
            // shortcut switches to note B, `.onChange(of: title)` skips updating `titleText` because
            // `isTitleFocused` is still (stalely) true, and the next commit renames note B using
            // note A's half-typed title. `.id(id)` removes the whole class rather than patching
            // that one field.
            NoteEditorScreen(noteID: id)
                .id(id)
        case .noteContainers:
            NoteContainersScreen()
        case .notePreview(let id):
            // Reached by an ordinary `push`, from `NoteBodyView` and from the fixture screenshot
            // workflow — never through `replace(with:)`, so this never hits the *same-depth*
            // reuse the two cases above guard against. Identity forced anyway, for the same
            // reason `.note` is: free, and it keeps every note-scoped destination consistent
            // rather than leaving one exception someone has to remember.
            NoteEditorScreen(noteID: id, startsInPreview: true)
                .id(id)
        case .notifications:
            NotificationCenterScreen()
        case .recordings:
            RecordingsRouteScreen()
        case .arcSpec(let specUuid):
            // The session this spec was opened from, if the currently open route names one —
            // read from the path rather than threaded through the route itself, since the route
            // carries no session identity of its own (see `Route.arcSpec`'s doc comment). This
            // is only ever an approximation of "which session pushed this screen": correct for
            // the ordinary case (push from the session currently on top, or from that session's
            // own in-session swipe), and simply `nil` — no live SSE signal, poll fallback only —
            // for anything less direct, which is the safe default already documented on
            // `ArcSpecView.sessionID`.
            ArcSpecView(specUuid: specUuid, sessionID: environment.router.openSessionID)
        case .apps:
            AppsRouteScreen()
        case .arcSpecList:
            ArcSpecListView()
        case .arcReport(let specUuid, let reportUuid):
            ArcReportScreen(specUuid: specUuid, reportUuid: reportUuid)
        case .arcOverview(let specUuid):
            ArcOverviewRouteScreen(specUuid: specUuid)
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
            // `Route.==` ignores `messageID` (deliberately — see its own doc comment), so
            // replacing an already-open `.session(id: sessionId)` with one that only differs by
            // `messageID` is invisible to `NavigationStack`: the destination is never rebuilt,
            // and `initialJumpMessageID` — the only thing that ever reads it — is a construction
            // parameter nothing re-delivers to a screen already on top. `TranscriptJumpRequests`
            // is the side channel that reaches it anyway, for exactly this case; the ordinary
            // "open the session at a message" case below is unaffected and unchanged.
            if environment.router.openSessionID == sessionId {
                if let messageID = notification.anchor?.messageId {
                    connection.transcriptJumps.request(sessionID: sessionId, messageID: messageID)
                }
            } else {
                environment.router.replace(with: [.session(id: sessionId, messageID: notification.anchor?.messageId)])
            }
        }
    }

    /// Builds and connects a fresh notification stream client, replacing whatever was there —
    /// safe to call more than once for the same reason `PushRegistrar.registerForRemoteNotificationsIfAuthorized`
    /// is: idempotent bookkeeping rather than a user-facing action. `onRead` is where rows 24.5
    /// and 24.7 actually meet — a read event both corrects the badge count immediately (through
    /// `applyLiveUnread`, which `.onChange(of: connection.notifications.unread)` above already
    /// mirrors into the springboard) and sweeps whatever delivered banners that same change just
    /// caught up with. `onNotification` only ever updates the count: the row itself is not
    /// injected into `NotificationCenterStore.rows`, since nothing reads that list outside the
    /// centre screen, which reloads its own page on entry regardless.
    private func connectNotificationStream(_ connection: AppEnvironment.Connection) {
        let store = connection.notifications
        let client = PaiNotificationStreamClient(
            requestFactory: connection.requestFactory,
            callbacks: PaiNotificationStreamClient.Callbacks(
                onNotification: { [weak store] event in
                    store?.applyLiveUnread(event.unread)
                },
                onRead: { [weak store] event in
                    store?.applyLiveUnread(event.unread)
                    guard let store else { return }
                    Task { await PushRegistrar.reconcileDeliveredNotifications(against: store) }
                },
                onActivity: {},
                onConnected: {},
                onDisconnected: {}
            )
        )
        notificationStream = client
        client.connect()
    }

    /// `nil` is "follow the system", which is what an absent override means to SwiftUI too.
    private var colorScheme: ColorScheme? {
        switch environment.connection?.settings.theme ?? .system {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// `set` only ever runs for a change `NavigationStack` itself drove — a swipe back, the back
    /// button, or a long-press jump to an ancestor — never for a programmatic push or replace,
    /// which mutate `Router.path` directly and reach this view through `get` on the next render.
    /// That is what makes `pathAfterLeavingSubagents` safe to apply unconditionally here: it must
    /// correct exactly the interactive case and never a deliberate `Router.replace(with:)` such
    /// as a notification's cold open, which intentionally lands somewhere `Route.subagents` knows
    /// nothing about.
    private var navigationPath: Binding<[Route]> {
        Binding(
            get: { environment.router.path },
            set: { newValue in
                let corrected = Route.pathAfterLeavingSubagents(from: environment.router.path, to: newValue)
                environment.router.replace(with: corrected)
            }
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

/// What `.apps` pushes to — reproduces the sheet the session list's "Apps" toolbar button
/// actually presents, since `AppsHomeSheet` has no screen of its own to navigate to. Shaped
/// exactly like `CreateSessionRouteScreen` above, for the same reason: real usage never pushes
/// this route, only the fixture screenshot workflow does.
private struct AppsRouteScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                AppsHomeSheet()
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

/// What `.arcOverview` pushes to — reproduces the sheet `ArcSpecView`'s own header button
/// presents, since the overview has no screen of its own to navigate to; real usage never
/// pushes this route, only the fixture screenshot workflow does. Fetches the overview text
/// directly rather than depending on `ArcSpecStore` having loaded, since the whole point is a
/// screenshot the app can reach with nothing else on screen underneath. Shaped exactly like
/// `CreateSessionRouteScreen` above, for the same reason.
private struct ArcOverviewRouteScreen: View {
    let specUuid: String
    @Environment(AppEnvironment.self) private var environment
    @State private var isPresented = true
    @State private var overview: String?

    var body: some View {
        Color.clear
            .task {
                guard let client = environment.connection?.apiClient else { return }
                overview = try? await client.getArcRecover(specUuid: specUuid).overview
            }
            .sheet(isPresented: $isPresented) {
                if let overview {
                    ArcMarkdownFullScreenView(markdown: overview, title: "Overview")
                }
            }
            .onChange(of: isPresented) { _, presented in
                guard !presented else { return }
                environment.router.pop()
            }
    }
}
