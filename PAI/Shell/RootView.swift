import PAIKit
import SwiftUI

/// The app's outermost screen: the gate, and the navigation stack behind it.
struct RootView: View {
    @State private var environment = AppEnvironment()

    var body: some View {
        content
            .preferredColorScheme(colorScheme)
            .task(id: environment.connection == nil) {
                await environment.loadStartupState()
                await environment.pollMachines()
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
                NavigationStack(path: navigationPath) {
                    SessionListView()
                        .navigationDestination(for: Route.self) { route in
                            destination(for: route)
                        }
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
