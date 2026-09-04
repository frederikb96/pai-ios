import PAIKit
import SwiftUI

/// Every ARC spec — the "Arc" entry under Apps. Row anatomy and list mechanics mirror
/// `SessionListView` on purpose ("the same picker style the session list uses", row 87's note):
/// a plain `List` giving fixed-height rows the virtualization the `scrolling` skill asks for, the
/// system search field rather than a hand-rolled one, and the same near-the-end pagination
/// trigger — scaled down from that screen's many sources to `ArcSpecListStore`'s single one,
/// since there is no synced list, no machine filter and no semantic mode here.
struct ArcSpecListView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: ArcSpecListStore?
    @State private var filterText = ""
    @State private var hasLoadedInitial = false

    /// Matches `SessionListView.loadMoreLeadRows` — a screen or so of lead at this row's fixed
    /// height, never the last row itself.
    private static let loadMoreLeadRows = 8

    var body: some View {
        Group {
            if let store {
                list(store: store)
            } else {
                centeredRow { ProgressView() }
            }
        }
        .paiScreenBackground()
        .navigationTitle("Arc")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $filterText, prompt: "Search specs…")
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = ArcSpecListStore(api: client)
            store = newStore
            await newStore.loadInitial(query: filterText)
            hasLoadedInitial = true
        }
        // Debounced the same way `NoteListScreen` debounces its own search: the view owns the
        // query text and `.task(id:)` cancels a superseded search on its own, so the store never
        // needs a second copy of that bookkeeping (`ArcSpecListStore`'s own doc comment).
        .task(id: filterText) {
            guard hasLoadedInitial else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await store?.loadInitial(query: filterText)
        }
        .accessibilityIdentifier("arc-spec-list")
    }

    private func list(store: ArcSpecListStore) -> some View {
        List {
            if store.isLoading && store.specs.isEmpty {
                centeredRow { ProgressView() }
            } else if let error = store.errorMessage, store.specs.isEmpty {
                centeredRow { emptyStateText(error) }
            } else if store.specs.isEmpty {
                centeredRow {
                    emptyStateText(
                        filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? "No specs yet" : "No matching specs")
                }
            } else {
                ForEach(Array(store.specs.enumerated()), id: \.element.uuid) { index, spec in
                    Button {
                        environment.router.push(.arcSpec(specUuid: spec.uuid))
                    } label: {
                        row(for: spec)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("arc-spec-row-\(spec.uuid)")
                    .onAppear {
                        guard store.hasMore, !store.isLoadingMore,
                            index >= store.specs.count - Self.loadMoreLeadRows
                        else { return }
                        Task { await store.loadMore(query: filterText) }
                    }
                }
                if store.isLoadingMore {
                    centeredRow { ProgressView() }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.loadInitial(query: filterText) }
    }

    private func row(for spec: ArcSpec) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.name)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(spec.phase)
                    if let activity = SessionTimeFormat.text(for: spec.updatedAt) {
                        Text(activity)
                    }
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            Spacer()
        }
        .padding(.vertical, 2)
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

    private func emptyStateText(_ text: String) -> some View {
        Text(text)
            .font(PaiTypography.body.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
    }
}
