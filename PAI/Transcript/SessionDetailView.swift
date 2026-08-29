import PAIKit
import SwiftUI

/// A session's transcript, and the composer under it.
///
/// The list here is deliberately provisional. The real one is a `UICollectionView` with
/// precomputed heights — see the repo's scrolling notes — and replaces this file wholesale.
struct SessionDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(TranscriptStore.self) private var transcript

    let sessionID: String

    var body: some View {
        Text("Transcript")
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .navigationTitle("Session")
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
}
