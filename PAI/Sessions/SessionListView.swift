import PAIKit
import SwiftUI

/// The app's first screen: the filter bar, the machine chips, and the session list itself.
///
/// Filter/chips sit above the `List` rather than inside it — the web keeps them fixed while the
/// rows scroll underneath, and a plain `List` already gives fixed-height rows the virtualization
/// the `scrolling` skill asks for, so nothing beyond that is needed here.
struct SessionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessions
    @Environment(MachineStore.self) private var machines

    /// The synced list (source A) has no loading state of its own in the store — it starts life
    /// already loaded via `loadInitialSessions()`. This tracks the one gap that leaves: the
    /// moment between the view appearing and that first await returning, when `rows` is
    /// genuinely empty but showing "No sessions yet" would be a false claim.
    @State private var hasLoadedInitialSessions = false
    @State private var isPresentingCreateSession = false

    /// How many rows before the end trigger the next page — a screen or so at this row's fixed
    /// height, never at the last row itself, per the `scrolling` skill.
    private static let loadMoreLeadRows = 8

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            if showsMachineChips {
                machineChips
            }
            Divider()
            list
        }
        .navigationTitle("Sessions")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingCreateSession = true
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityIdentifier("new-session")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("open-settings")
            }
        }
        .task {
            // Guarded, because pushing a session and coming back may re-run this: a second
            // `loadInitialSessions` replaces the list wholesale and resets the paging cursor, so
            // returning from a session would silently discard everything scrolled to so far.
            // Guarded, because pushing a session and coming back re-runs this: a second
            // `loadInitialSessions` replaces the list wholesale and resets the paging cursor, so
            // returning from a session would silently discard everything scrolled to so far.
            guard !hasLoadedInitialSessions else { return }
            await sessions.loadInitialSessions()
            hasLoadedInitialSessions = true
        }
        .sheet(isPresented: $isPresentingCreateSession) {
            CreateSessionView()
        }
    }

    // MARK: - The list

    private var list: some View {
        List {
            content
        }
        .listStyle(.plain)
        .refreshable {
            // Server-filtered results (a machine chip or a query) go stale by design while
            // active — nothing pushes into them, and this pull only ever refreshes the synced
            // list, matching how the web restores the live picture: by clearing filters, not by
            // this gesture.
            await sessions.pollSyncedSessions()
        }
        .accessibilityIdentifier("session-list")
    }

    @ViewBuilder
    private var content: some View {
        if !hasLoadedInitialSessions && !sessions.isServerFiltered {
            centeredRow { ProgressView() }
        } else {
            switch sessions.emptyState {
            case .none:
                EmptyView()
            case .loadingFirstResults:
                centeredRow { ProgressView() }
            case .noSessionsYet:
                centeredRow { emptyStateText("No sessions yet") }
            case .noMatchingSessions:
                centeredRow { emptyStateText("No matching sessions") }
            }

            ForEach(Array(sessions.rows.enumerated()), id: \.element.id) { index, row in
                SessionRowButton(row: row) {
                    environment.router.push(.session(id: row.id))
                }
                .onAppear {
                    guard sessions.hasMoreRows, !sessions.isLoadingMoreRows,
                        index >= sessions.rows.count - Self.loadMoreLeadRows
                    else { return }
                    Task { await sessions.loadMoreRows() }
                }
            }

            if sessions.isLoadingMoreRows {
                centeredRow { ProgressView() }
            }
        }
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

    // MARK: - Filter bar

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                    TextField(filterPlaceholder, text: filterTextBinding)
                        .textFieldStyle(.plain)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                        .onSubmit { sessions.commitFilterTextNow() }
                        .accessibilityIdentifier("session-filter-field")
                    if !sessions.filterQueryText.isEmpty {
                        Button {
                            sessions.updateFilterText("")
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(PaiPalette.Semantic.textFaint)
                        }
                        .accessibilityIdentifier("session-filter-clear")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 8))

                Button {
                    sessions.setSemanticMode(!sessions.semanticMode)
                } label: {
                    Image(systemName: "sparkles")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.bordered)
                .tint(sessions.semanticMode ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textMuted)
                .accessibilityLabel("Search by meaning, not just text")
                .accessibilityAddTraits(sessions.semanticMode ? [.isSelected] : [])
                .accessibilityIdentifier("semantic-toggle")
            }

            if showsThresholdSlider {
                HStack(spacing: 8) {
                    Text("Match")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    Slider(value: thresholdBinding, in: 0...1, step: 0.01)
                        .accessibilityLabel("Minimum match score")
                    Text(thresholdPercentText)
                        .font(PaiTypography.monoLabel.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .monospacedDigit()
                        .frame(minWidth: 36, alignment: .trailing)
                }
            }

            if let error = sessions.searchError {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).lineLimit(1)
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var filterTextBinding: Binding<String> {
        Binding(get: { sessions.filterQueryText }, set: { sessions.updateFilterText($0) })
    }

    private var thresholdBinding: Binding<Double> {
        Binding(get: { sessions.threshold }, set: { sessions.setThreshold($0) })
    }

    private var filterPlaceholder: String {
        sessions.semanticMode ? "Search by meaning…" : "Filter sessions or paste an id…"
    }

    private var thresholdPercentText: String {
        "\(Int((sessions.threshold * 100).rounded()))%"
    }

    /// Mirrors the web's `semanticMode && textQuery !== undefined`: a live, non-id query, in
    /// semantic mode. `filterQueryText` rather than the store's internal debounced query — the
    /// web shows this the instant there is text, not only once the debounce settles.
    private var showsThresholdSlider: Bool {
        sessions.semanticMode && !sessions.isIdQuery
            && !sessions.filterQueryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Machine chips

    /// Only earns its place once there is a choice to make — one machine means no chips at all,
    /// not a disabled row.
    private var showsMachineChips: Bool {
        MachineStore.hasMultipleAgents(machines.allMachines)
    }

    private var machineChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                MachineChip(title: "All", isSelected: sessions.machineFilter == nil) {
                    sessions.setMachineFilter(nil)
                }
                // Offline machines stay selectable here, unlike the launch picker: this filters
                // what to look at, not where to launch, and a grey laptop session is exactly
                // what a chip here is for finding.
                ForEach(machines.allMachines) { machine in
                    MachineChip(title: machine.displayName, isSelected: sessions.machineFilter == machine.slug) {
                        sessions.setMachineFilter(machine.slug)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 6)
    }
}

/// A tappable row wrapper — `SessionRow` itself stays a plain display view.
private struct SessionRowButton: View {
    let row: SessionListRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SessionRow(row: row)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("session-row-\(row.id)")
    }
}

/// One machine filter pill. Selection is shown by fill and colour, never colour alone, matching
/// the accessible radiogroup semantics `AgentFilterChips` uses on the web.
private struct MachineChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(PaiTypography.captionEmphasized.font)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isSelected ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                    in: Capsule()
                )
                .foregroundStyle(
                    isSelected ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textSecondary
                )
                .overlay(
                    Capsule().strokeBorder(PaiPalette.Semantic.borderDefault, lineWidth: isSelected ? 0 : 1)
                )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// One row: state dot, warnings, title, when it last did anything.
///
/// Deliberately spare, matching the web. The machine a session runs on is **not** shown, so with
/// no machine filter applied a VM row and a laptop row look identical — that is the web's choice
/// and changing it is an addition, not a port.
struct SessionRow: View {
    let row: SessionListRow

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayTitle)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)

                if let activity = SessionTimeFormat.text(for: row.lastActivityAt) {
                    Text(activity)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if row.showsBlockedWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                    .accessibilityLabel("Waiting on you")
            }
            if row.showsAttentionWarning {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .accessibilityLabel("Needs attention")
            }
            if row.showsTokenCount {
                Text(SessionListFormat.formatTokens(row.sessionTokens))
                    .font(PaiTypography.monoLabel.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .padding(.vertical, 2)
    }

    /// Grey is normal, not an error — it means the session is not driven by the backend, which is
    /// true of a subagent and of anything Freddy runs in his own terminal.
    private var dotColor: Color {
        switch row.dotState {
        case .ready, .legacyActive: PaiPalette.green500
        case .starting, .blocked, .legacyPending: PaiPalette.amber500
        case .attention, .legacyError: PaiPalette.red500
        case .closed, .grey, .legacyCompleted, .legacyInterrupted: PaiPalette.surface400
        }
    }
}

/// The row's timestamp string — pure presentation over `SessionListFormat.timeBucket`, which is
/// the tested half; picking a `DateFormatter`/`Date.FormatStyle` template per bucket is left to
/// the view on purpose (see that type's doc comment).
enum SessionTimeFormat {
    private static let fractionalParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let parser = ISO8601DateFormatter()

    static func text(for isoString: String?) -> String? {
        guard let isoString, let date = parse(isoString) else { return nil }
        switch SessionListFormat.timeBucket(for: date) {
        case .today:
            return date.formatted(date: .omitted, time: .shortened)
        case .thisWeek:
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .older:
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private static func parse(_ text: String) -> Date? {
        fractionalParser.date(from: text) ?? parser.date(from: text)
    }
}
