import PAIKit
import SwiftUI

/// Every open decision across the owner's sessions, grouped by session, the session with the
/// newest decision first. Answered here exactly as in the pin above a transcript; the session's
/// title opens it. Swift port of `DecisionsApp.tsx`.
struct DecisionsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if let store = environment.connection?.decisions {
                content(store)
                    .task { await store.refresh() }
                    .refreshable { await store.refresh() }
            } else {
                ProgressView()
            }
        }
        .paiScreenBackground()
        .navigationTitle("Decisions")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("decisions-screen")
    }

    @ViewBuilder
    private func content(_ store: DecisionsStore) -> some View {
        let groups = store.groups
        if groups.isEmpty {
            ScrollView {
                Text("No decision is waiting on you.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(32)
            }
        } else {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                environment.router.push(.session(id: group.sessionId))
                            } label: {
                                HStack {
                                    Text(group.sessionTitle ?? "Untitled session")
                                        .font(PaiTypography.bodyEmphasized.font)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Image(systemName: "arrow.up.right.square")
                                }
                                .padding(12)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider()
                            DecisionListView(sessionId: group.sessionId, decisions: group.decisions)
                        }
                        .background(BannerTone.accent.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(BannerTone.accent.border))
                    }
                }
                .padding(12)
            }
        }
    }
}
