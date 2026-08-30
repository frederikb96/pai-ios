import PAIKit
import SwiftUI
import UIKit

/// A session's transcript, and the composer under it.
///
/// The list is a `UICollectionView` wrapped for SwiftUI (``TranscriptCollectionView``) — not a
/// plain SwiftUI `List` — with row heights precomputed and cached, never self-sized. See the
/// `scrolling` skill for why.
struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(TranscriptStore.self) private var transcript
    @Environment(SettingsStore.self) private var settings
    @State private var searchState = TranscriptSearchState()

    let sessionID: String

    var body: some View {
        Group {
            if let connection = environment.connection {
                VStack(spacing: 0) {
                    TranscriptCollectionView(
                        sessionID: sessionID, store: transcript, apiClient: connection.apiClient, settings: settings,
                        requestFactory: connection.requestFactory, searchState: searchState)
                    Divider()
                    if searchState.isActive {
                        TranscriptSearchBar(state: searchState)
                    } else {
                        ComposerBar(sessionID: sessionID)
                    }
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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    searchState.open()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .accessibilityIdentifier("open-transcript-search")
            }
        }
    }

    private var navigationTitle: String {
        // Searched, not just synced: a search result older than the loaded pages is not in the
        // synced list at all, and looking only there titles it "Session".
        guard let session = environment.connection?.sessions.session(withId: sessionID) else {
            return "Session"
        }
        return SessionListFormat.displayTitle(for: session)
    }
}
