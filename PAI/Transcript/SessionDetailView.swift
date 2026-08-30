import Foundation
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
                    TranscriptStreamStallBanner(sessionID: sessionID)
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

/// Warns when the transcript's SSE connection sits open and silent while a turn is still expected
/// to produce output — the counterpart to `TerminalScreen`'s status dot, shown only when there is
/// something worth saying rather than as a permanent bar, since the common case (connected,
/// flowing, or genuinely idle between turns) needs no comment. `isProcessing` is what makes this
/// safe to call a stall rather than a guess: without it, a quiet session with nothing to say would
/// read identically to a stream that has gone silent mid-turn.
private struct TranscriptStreamStallBanner: View {
    @Environment(TranscriptStore.self) private var transcript
    let sessionID: String

    /// Independent of `TerminalScreen`'s own thresholds — the two streams are separate
    /// connections and there is no reason their timing has to match.
    private static let idleThreshold: TimeInterval = 3
    private static let stallThreshold: TimeInterval = 10

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let text = message(now: context.date) {
                HStack(spacing: 6) {
                    Image(systemName: "wifi.exclamationmark")
                    Text(text)
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.amber500)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("transcript-stream-stall-banner")
            }
        }
    }

    private func message(now: Date) -> String? {
        guard transcript.isProcessing(for: sessionID) else { return nil }
        let state = transcript.sseActivity(for: sessionID).state(
            now: now, idleThreshold: Self.idleThreshold, stallThreshold: Self.stallThreshold)
        guard case .stalled(let elapsed) = state else { return nil }
        let seconds = Int(elapsed.rounded())
        return "No updates for \(seconds)s — still working?"
    }
}
