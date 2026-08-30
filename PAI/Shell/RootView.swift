import PAIKit
import SwiftUI

/// The app's outermost screen: the gate, and the navigation stack behind it.
struct RootView: View {
    @State private var environment = AppEnvironment()
    /// Whatever `CrashReporter` captured before this launch, if any — read once on appear rather
    /// than continuously, since nothing after launch can change what already happened before it.
    @State private var pendingCrash: CrashRecord?

    var body: some View {
        content
            .preferredColorScheme(colorScheme)
            .task(id: environment.connection == nil) {
                await environment.loadStartupState()
                await environment.pollMachines()
            }
            .onAppear { pendingCrash = CrashReporter.readLast() }
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
private struct CreateSessionRouteScreen: View {
    @State private var isPresented = true

    var body: some View {
        Color.clear
            .sheet(isPresented: $isPresented) {
                CreateSessionView()
            }
    }
}
