import PAIKit
import SwiftUI

/// The app's first screen: the machine chips, the session list, and the system search field.
///
/// The search field is `.searchable`, not a hand-rolled one — the platform gives scroll-to-reveal
/// and a Cancel button for free, which is exactly what the web has to build by hand because it
/// has no such control to reach for. A plain `List` already gives fixed-height rows the
/// virtualization the `scrolling` skill asks for, so nothing beyond that is needed here.
struct SessionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessions
    @Environment(MachineStore.self) private var machines
    @Environment(NotificationCenterStore.self) private var notifications

    /// The synced list (source A) has no loading state of its own in the store — it starts life
    /// already loaded via `loadInitialSessions()`. This tracks the one gap that leaves: the
    /// moment between the view appearing and that first await returning, when `rows` is
    /// genuinely empty but showing "No sessions yet" would be a false claim.
    @State private var hasLoadedInitialSessions = false
    @State private var isPresentingCreateSession = false
    @State private var actionsSheetTarget: SessionActionsTarget?
    @State private var arcSpecTarget: ArcSpecPickerTarget?

    /// How many rows before the end trigger the next page — a screen or so at this row's fixed
    /// height, never at the last row itself, per the `scrolling` skill.
    private static let loadMoreLeadRows = 8

    var body: some View {
        VStack(spacing: 0) {
            if showsMachineChips {
                machineChips
            }
            list
        }
        .paiScreenBackground()
        .navigationTitle("Sessions")
        // The system search field: scroll-to-reveal and a Cancel button for free, rather than
        // the hand-rolled field the web needs (it has no such control to reach for).
        .searchable(text: filterTextBinding, prompt: filterPlaceholder)
        .onSubmit(of: .search) { sessions.commitFilterTextNow() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingCreateSession = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("new-session")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.notes)
                } label: {
                    Image(systemName: "note.text")
                }
                .accessibilityLabel("Notes")
                .accessibilityIdentifier("open-notes")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("open-settings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    sessions.setSemanticMode(!sessions.semanticMode)
                } label: {
                    Image(systemName: "sparkles")
                }
                .tint(sessions.semanticMode ? PaiPalette.Semantic.accentText : nil)
                .accessibilityLabel("Search by meaning, not just text")
                .accessibilityAddTraits(sessions.semanticMode ? [.isSelected] : [])
                .accessibilityIdentifier("semantic-toggle")
            }
            // Fifth trailing item, at the toolbar's own limit (row 5.27 note 8) — nothing here
            // moves into an overflow yet, since whether it actually crowds a real phone is a
            // question only a Mac run's screenshot can answer.
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.notifications)
                } label: {
                    Image(systemName: notifications.unread > 0 ? "bell.badge" : "bell")
                }
                .accessibilityLabel(
                    notifications.unread > 0
                        ? "Notifications, \(notifications.unread) unread" : "Notifications"
                )
                .accessibilityIdentifier("open-notifications")
            }
        }
        .task {
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
        .sheet(item: $actionsSheetTarget) { target in
            SessionActionsSheet(sessionId: target.id)
        }
        .arcSpecPicker($arcSpecTarget, router: environment.router)
    }

    // MARK: - The list

    private var list: some View {
        List {
            if showsThresholdSlider {
                thresholdRow
                    .listRowSeparator(.hidden)
            }
            if let error = sessions.searchError {
                searchErrorRow(error)
                    .listRowSeparator(.hidden)
            }
            content
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
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
                // Swipe and long press both land on the same sheet, and neither one destroys
                // anything by itself. A swipe is a gesture a thumb makes by accident while
                // scrolling a list, so wiring it straight to Delete puts the one irreversible
                // action behind the most easily-triggered gesture — Delete still lives one tap
                // further in, inside the sheet, alongside everything else a session can do.
                .swipeActions(edge: .trailing) {
                    Button {
                        actionsSheetTarget = SessionActionsTarget(id: row.id)
                    } label: {
                        Label("Actions", systemImage: "ellipsis.circle")
                    }
                    .tint(PaiPalette.primary500)
                    // A subagent's own children are flattened into its top-level parent — see
                    // `RootActionsList`'s matching guard — so this swipe action has nothing to
                    // open for one either.
                    if row.session.kind != .subagent {
                        Button {
                            environment.router.push(.subagents(parentID: row.id))
                        } label: {
                            Label("Subagents", systemImage: "cpu")
                        }
                        .tint(PaiPalette.Semantic.accentText)
                    }
                    Button {
                        arcSpecTarget = ArcSpecPickerTarget(
                            sessionID: row.id, claudeSessionID: row.session.claudeSessionId)
                    } label: {
                        Label("Spec", systemImage: "shippingbox")
                    }
                    .tint(PaiPalette.Semantic.warningText)
                }
                // `.highPriorityGesture`, not `.onLongPressGesture`: the row is a `Button`, and a
                // bare gesture modifier competes with the button's own tap recognition rather than
                // taking precedence over it — which resolves inconsistently, and the way it goes
                // wrong is a long press that opens the sheet *and* navigates into the session on
                // release. A long press that never reaches its duration still fails cleanly and
                // leaves the tap to the button.
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in actionsSheetTarget = SessionActionsTarget(id: row.id) }
                )
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

    // MARK: - Filter accessories
    //
    // The search FIELD itself is `.searchable` on the body above — these are the two things that
    // do not fit that control: the semantic-match threshold slider, and a search-specific error.
    // Both live as ordinary first rows in the list rather than pinned chrome, since neither
    // applies outside an active semantic search.

    private var thresholdRow: some View {
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

    private func searchErrorRow(_ error: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(error).lineLimit(1)
        }
        .font(PaiTypography.caption.font)
        .foregroundStyle(PaiPalette.Semantic.errorText)
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
                // Without this the row answers only where it draws — its title, its timestamp,
                // its badges — and the empty width its `Spacer()` opens up is dead. The same
                // shape is what the long-press gesture below hit-tests against, so a press in
                // that gap opened nothing either.
                .contentShape(Rectangle())
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

/// The `.sheet(item:)` target for the session actions sheet — a plain id wrapped just enough to
/// be `Identifiable`, since `String` alone cannot be used as a sheet item.
private struct SessionActionsTarget: Identifiable {
    let id: String
}

/// One row: state dot (or a working spinner in its place), warnings, title, when it last did
/// anything, token count, and what it has running — matching what the web's row shows, denser
/// than the row this replaces. 🚨 The spinner is sized to the dot it replaces so a working row is
/// never taller than an idle one — see `SessionStateIndicator`'s doc comment and the `scrolling`
/// skill.
struct SessionRow: View {
    let row: SessionListRow

    var body: some View {
        HStack(spacing: 10) {
            SessionStateIndicator(dotState: row.dotState, isWorking: row.isWorking)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayTitle)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let activity = SessionTimeFormat.text(for: row.lastActivityAt) {
                        Text(activity)
                            .lineLimit(1)
                    }
                    if let counts = row.activityCounts, counts.agents > 0 || counts.tasks > 0 {
                        ActivityBadges(counts: counts)
                    }
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
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
}

/// What a session has running right now — subagents and background shells/monitors. Each half
/// disappears on its own at zero, matching `ActivityBadges.tsx`, so a number on screen always
/// means something is actually running. Shown in the list beside a row's timestamp and in the
/// session header beside its token figure, exactly as the web shows it in both places.
struct ActivityBadges: View {
    let counts: ActivityCounts

    var body: some View {
        HStack(spacing: 6) {
            if counts.agents > 0 {
                Label("\(counts.agents)", systemImage: "cpu")
                    .accessibilityLabel("\(counts.agents) subagent(s) working right now")
            }
            if counts.tasks > 0 {
                Label("\(counts.tasks)", systemImage: "terminal")
                    .accessibilityLabel("\(counts.tasks) background task(s) running")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(PaiTypography.caption.font)
    }
}

/// The row's timestamp string — pure presentation over `SessionListFormat.timeBucket`, which is
/// the tested half; picking a `DateFormatter`/`Date.FormatStyle` template per bucket is left to
/// the view on purpose (see that type's doc comment).
enum SessionTimeFormat {

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
        IsoTimestamp.date(from: text)
    }
}
