import PAIKit
import SwiftUI
import UIKit

/// A session's transcript, and the composer under it.
///
/// The list is a `UICollectionView` wrapped for SwiftUI (``TranscriptCollectionView``) — not a
/// plain SwiftUI `List` — with row heights precomputed and cached, never self-sized. See the
/// `scrolling` skill and this block's report for why.
struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(TranscriptStore.self) private var transcript
    @Environment(SettingsStore.self) private var settings

    let sessionID: String

    var body: some View {
        Group {
            if let connection = environment.connection {
                VStack(spacing: 0) {
                    TranscriptCollectionView(
                        sessionID: sessionID, store: transcript, apiClient: connection.apiClient, settings: settings,
                        requestFactory: connection.requestFactory)
                    Divider()
                    ComposerBar(sessionID: sessionID)
                }
            } else {
                // Unreachable in practice: `RootView` only shows this screen once the connection
                // exists. A spinner rather than an empty screen, so the impossible case still
                // reads as "not yet" instead of as a broken view.
                ProgressView()
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("session-detail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.terminal(sessionID: sessionID))
                } label: {
                    Image(systemName: "terminal")
                }
                .accessibilityIdentifier("open-terminal")
            }
        }
    }

    private var navigationTitle: String {
        guard let session = environment.connection?.sessions.syncedSessions.first(where: { $0.id == sessionID }) else {
            return "Session"
        }
        return SessionListFormat.displayTitle(for: session)
    }

    /// The transcript stream needs its own `Authorization` header the same way every other
    /// transport does (`PaiRequestFactory`'s doc comment) — `PaiApiClient` keeps its copy
    /// private, so this rebuilds one from the same backend URL and the same Keychain entry
    /// `AppEnvironment` itself reads, rather than reaching into its private state.
}
