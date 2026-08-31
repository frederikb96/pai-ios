import PAIKit
import SwiftUI

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
                await environment.pollMachines()
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
            .sheet(item: $pendingCrash, onDismiss: { CrashReporter.clearLast() }) { crash in
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
                    ToastOverlay(toasts: connection.toasts)
                }
                // The one page ground for every screen the stack pushes — none of them paint
                // their own, so this is what stops each one falling through to pure black. See
                // `paiScreenBackground()`'s own doc comment for why that step matters.
                .paiScreenBackground()
                .environment(environment)
                .environment(connection.sessions)
                .environment(connection.machines)
                .environment(connection.transcript)
                .environment(connection.settings)
                .environment(connection.drafts)
                .environment(connection.me)
                .environment(connection.toasts)
                .environment(connection.notes)
                .environment(connection.notesBrowse)
                .environment(connection.staging)
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
        case .session(let id):
            SessionDetailView(sessionID: id)
        case .terminal(let sessionID):
            TerminalScreen(sessionID: sessionID)
        case .settings:
            SettingsScreen()
        case .createSession:
            CreateSessionRouteScreen()
        case .notes:
            NoteListScreen()
        case .note(let id):
            NoteEditorScreen(noteID: id)
        case .noteContainers:
            NoteContainersScreen()
        case .notePreview(let id):
            NoteEditorScreen(noteID: id, startsInPreview: true)
        }
    }

    /// Act on a parked deep link, but only once there is a signed-in app to act on it in.
    ///
    /// Left in the inbox otherwise rather than dropped: a notification tapped from cold arrives
    /// well before the token has been read and the connection built, and discarding it there is
    /// exactly the case this whole mechanism exists for.
    private func consumeDeepLink() {
        guard environment.router.gate == .ready, environment.connection != nil else { return }
        guard let link = deepLinks.consume() else { return }
        environment.router.replace(with: link.routes)
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
