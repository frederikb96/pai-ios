import PAIKit
import SwiftUI

/// One conversation's own subagents — reached from its actions menu, newest activity first.
/// Selecting one opens it in the ordinary transcript view; a subagent has no menu item of its
/// own to reach this screen a second time (`RootActionsList` hides it for `kind == .subagent`).
///
/// Kept live the same way the web is: it watches the parent session's own `activityCounts.agents`
/// — a value the app-wide session poll already keeps current regardless of what is on screen —
/// rather than subscribing to any stream of its own. See `SubagentListStore`'s doc comment for
/// why a per-screen subscription would not be a reliable signal here.
struct SubagentListScreen: View {
    let parentSessionId: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessionList

    @State private var store: SubagentListStore?
    @State private var hasLoadedInitial = false
    /// The row a prepend must keep in view — captured right before a `noteParentAgentsCount` call
    /// that turns out to have prepended, and consumed by the very next layout of `store.subagents`
    /// below. `nil` the rest of the time, so an ordinary append-at-bottom or an in-place-only
    /// refresh never triggers a scroll it does not need.
    @State private var pendingScrollAnchor: String?
    /// The topmost row currently on screen — a single mechanism doing both jobs `scrollPosition`
    /// is for: SwiftUI updates it as the reader scrolls, and setting it programmatically scrolls
    /// there. Read-only here; the actual correction is driven through `ScrollViewReader` below, so
    /// there is exactly one thing moving the list rather than two mechanisms racing each other.
    @State private var topRowID: String?

    private static let loadMoreLeadRows = 8

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if let store {
                    list(store: store)
                        .onChange(of: store.subagents) { _, _ in
                            guard let anchor = pendingScrollAnchor else { return }
                            pendingScrollAnchor = nil
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                } else {
                    centeredProgress
                }
            }
        }
        .navigationTitle("Subagents")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = SubagentListStore(parentSessionId: parentSessionId, api: client)
            store = newStore
            await newStore.loadInitial()
            hasLoadedInitial = true
        }
        .onChange(of: parentAgentsCount) { _, newCount in
            guard let store else { return }
            let anchor = topRowID
            Task {
                if await store.noteParentAgentsCount(newCount) {
                    pendingScrollAnchor = anchor
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let parentTitle {
                Text("of \(parentTitle)")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 4)
            }
        }
    }

    private var parentTitle: String? {
        sessionList.session(withId: parentSessionId).map(SessionListDomain.sessionHeaderTitle(for:))
    }

    /// Kept current by the app-wide session poll (and sooner by SSE while the parent happens to
    /// be the open conversation) regardless of whether this screen is on screen at all.
    private var parentAgentsCount: Int {
        sessionList.session(withId: parentSessionId)?.activityCounts?.agents ?? 0
    }

    @ViewBuilder
    private func list(store: SubagentListStore) -> some View {
        List {
            if !hasLoadedInitial {
                centeredRow { ProgressView() }
            } else if store.subagents.isEmpty, !store.isLoading {
                centeredRow {
                    Text("No subagents yet")
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }

            ForEach(Array(store.subagents.enumerated()), id: \.element.id) { index, subagent in
                Button {
                    environment.router.push(.session(id: subagent.id))
                } label: {
                    SubagentRow(session: subagent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .id(subagent.id)
                .onAppear {
                    guard store.hasMore, !store.isLoading, index >= store.subagents.count - Self.loadMoreLeadRows
                    else { return }
                    Task { await store.loadMore() }
                }
            }

            if store.isLoading, hasLoadedInitial {
                centeredRow { ProgressView() }
            }
            if let error = store.errorMessage {
                centeredRow {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollPosition(id: $topRowID)
        .accessibilityIdentifier("subagent-list")
    }

    private var centeredProgress: some View {
        centeredRow { ProgressView() }
    }

    @ViewBuilder
    private func centeredRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        HStack {
            Spacer()
            content()
            Spacer()
        }
        .padding(.vertical, 24)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

/// One subagent — its own name or type, the type badge when both are known, its description, and
/// when it last did anything. Matches the web's `SubagentPanel.tsx` row.
private struct SubagentRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .foregroundStyle(PaiPalette.Semantic.textFaint)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.subagentName ?? session.subagentType ?? "an unnamed agent")
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        .lineLimit(1)
                    if let type = session.subagentType, session.subagentName != nil {
                        Text(type)
                            .font(PaiTypography.captionEmphasized.font)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(PaiPalette.Semantic.raisedSurface, in: Capsule())
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
                if let description = session.subagentDescription {
                    Text(description)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            // Only shown when actually known: a `nil` means the spawn inherited its model, not
            // that it ran on a default.
            let trailing = [session.subagentModel, SessionTimeFormat.text(for: session.lastActivityAt)]
                .compactMap { $0 }.joined(separator: " · ")
            if !trailing.isEmpty {
                Text(trailing)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .frame(minHeight: 56)
        .padding(.vertical, 2)
    }
}
