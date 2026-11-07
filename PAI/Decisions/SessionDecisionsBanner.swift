import PAIKit
import SwiftUI

/// A session's open decisions, pinned above the transcript so they never scroll away with it.
/// Swift port of `DecisionsBanner.tsx`. Draws nothing while nothing is open (and for a guest,
/// whose store never holds any); scrolls inside a bounded height so a long list cannot push the
/// transcript off a phone.
struct SessionDecisionsBanner: View {
    @Environment(AppEnvironment.self) private var environment
    let sessionID: String

    private static let maxHeight: CGFloat = 320

    var body: some View {
        if let store = environment.connection?.decisions {
            let decisions = store.decisions(forSession: sessionID)
            Group {
                if !decisions.isEmpty {
                    DecisionListView(sessionId: sessionID, decisions: decisions, maxHeight: Self.maxHeight)
                        .background(BannerTone.accent.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BannerTone.accent.border))
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("decisions-banner")
                }
            }
            .task(id: sessionID) { await store.refresh() }
        }
    }
}
