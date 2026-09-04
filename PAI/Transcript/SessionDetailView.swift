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
    @Environment(SessionListStore.self) private var sessions
    @Environment(TranscriptStore.self) private var transcript
    @Environment(SettingsStore.self) private var settings
    @State private var searchState = TranscriptSearchState()
    @State private var isPresentingActionsSheet = false
    @State private var isPresentingArcMenu = false
    @State private var arcSpecTarget: ArcSpecResolution?
    @State private var usage: Usage?
    /// Whether this screen has ever seen its session exist. Until it has, a `nil` lookup means
    /// "not fetched yet" — a deep link or a restored route can name a session outside every page
    /// the list has loaded — and leaving on that would close the screen before it opened.
    @State private var hasResolvedSession = false

    let sessionID: String
    /// Where to jump once the transcript is open — set only when this screen was reached from a
    /// notification (row 5.28). `nil` for an ordinary open, which restores the last-read position
    /// exactly as before.
    var initialJumpMessageID: Int? = nil

    var body: some View {
        Group {
            if let connection = environment.connection {
                VStack(spacing: 0) {
                    headerStrip
                    TranscriptCollectionView(
                        sessionID: sessionID, store: transcript, apiClient: connection.apiClient, settings: settings,
                        requestFactory: connection.requestFactory, searchState: searchState,
                        initialJumpMessageID: initialJumpMessageID, jumpRequests: connection.transcriptJumps,
                        persistedReadPosition: currentSession.map {
                            PersistedReadPosition(
                                messageId: $0.readPositionMessageId, offsetPx: $0.readPositionOffsetPx,
                                atBottom: $0.readPositionAtBottom ?? false)
                        }
                    )
                    .overlay { TranscriptLoadState(sessionID: sessionID) }
                    .overlay(alignment: .top) { TranscriptOlderPageState(sessionID: sessionID) }
                    .overlay(alignment: .bottom) { TranscriptStreamStallBanner(sessionID: sessionID) }
                    Divider()
                    if searchState.isActive {
                        TranscriptSearchBar(state: searchState)
                    } else {
                        ComposerBar(sessionID: sessionID)
                    }
                }
                // `.simultaneousGesture` rather than `.gesture`: this must never win exclusivity
                // over the transcript's own UIKit scroll/pan recognizers or a code block's
                // horizontal scroll — it only ever ADDS a recognizer alongside them. The width
                // threshold is what keeps an ordinary vertical scroll from ever satisfying it;
                // see PORTING.md for what remains unverified about how this behaves against the
                // wrapped `UICollectionView` on a real device.
                .simultaneousGesture(
                    DragGesture(minimumDistance: 30)
                        .onEnded { value in
                            guard value.translation.width < -70, abs(value.translation.height) < 60 else { return }
                            isPresentingArcMenu = true
                        }
                )
            } else {
                // Unreachable in practice: `RootView` only shows this screen once the connection
                // exists. A spinner rather than an empty screen, so the impossible case still
                // reads as "not yet" instead of as a broken view.
                ProgressView()
            }
        }
        .paiScreenBackground()
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("session-detail")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPresentingActionsSheet = true
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityIdentifier("session-actions-button")
            }
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
        .sheet(isPresented: $isPresentingActionsSheet) {
            SessionActionsSheet(sessionId: sessionID)
        }
        // The same three the session list's own trailing swipe offers (`SessionListView`) — see
        // that swipe's own doc comment for why "Subagents" is skipped for a subagent itself.
        .confirmationDialog("Session", isPresented: $isPresentingArcMenu, titleVisibility: .hidden) {
            Button("Actions") { isPresentingActionsSheet = true }
            if currentSession?.kind != .subagent {
                Button("Subagents") { environment.router.push(.subagents(parentID: sessionID)) }
            }
            Button("Spec") {
                Task {
                    arcSpecTarget = await resolveArcSpec(
                        claudeSessionID: currentSession?.claudeSessionId,
                        api: environment.connection?.apiClient, router: environment.router)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .arcSpecPicker($arcSpecTarget, router: environment.router)
        .task {
            // A route restored after relaunch, or a deep link, can name a session outside every
            // page the list has loaded — this is what makes it resolvable regardless.
            await sessions.ensureSessionLoaded(id: sessionID)
        }
        #if DEBUG
            .task {
                // `-PaiFixtureSearchKind <kind>` — the Mac workflow's own way to drive a jump
                // landing with no device interaction. Opens the same way tapping the search icon
                // does, through the state `TranscriptCollectionViewController` already observes,
                // so this exercises exactly the search-virtualization landing path rather than a
                // shortcut invented for the screenshot.
                guard PaiFixtureLaunch.isEnabled(), let rawKind = PaiFixtureLaunch.requestedSearchKind(),
                    let kind = MessageKind(rawValue: rawKind)
                else { return }
                searchState.open()
                searchState.kind = kind
            }
        #endif
        // The session this screen is *about* stopped existing — deleted from the actions sheet
        // right here, or from another client. Without this the transcript and composer stay live
        // and typeable over a session that is gone: the header quietly empties, the title falls
        // back to "Session", and nothing says why or offers a way out.
        .onChange(of: currentSession == nil) { _, isGone in
            guard hasResolvedSession, isGone else { return }
            environment.router.dismissSession(id: sessionID)
        }
        .onChange(of: currentSession != nil) { _, exists in
            if exists { hasResolvedSession = true }
        }
        .onAppear {
            if currentSession != nil { hasResolvedSession = true }
        }
        // Routes the transcript's own live SSE `status` event into the session list the moment
        // it changes, so the list (and this header, which reads through the same store) reflect
        // it while this screen is open rather than waiting for the 10s poll — see
        // `TranscriptStore.liveStatus`'s doc comment. One mutator, one call site.
        .onChange(of: transcript.liveStatus[sessionID]) { _, newValue in
            guard let newValue else { return }
            sessions.applyLiveStatus(
                sessionId: sessionID, state: newValue.state, blocker: newValue.blocker, working: newValue.working,
                presenceState: newValue.presenceState, activityCounts: newValue.activityCounts
            )
        }
        .task {
            // The account's plan usage — not per-session, but this header is where Freddy is
            // already looking to decide whether to keep going or wait for the window to reset.
            guard let client = environment.connection?.apiClient else { return }
            while !Task.isCancelled {
                usage = try? await client.getUsage()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    // MARK: - Header strip
    //
    // A `UINavigationBar` cannot carry a dot, a spinner, live tokens and a usage badge at once —
    // this strip is that placement decision, sitting below the bar with the plain nav title
    // (`navigationTitle` above) left to carry just the name.
    private var headerStrip: some View {
        Group {
            if let session = currentSession {
                HStack(spacing: 10) {
                    SessionStateIndicator(
                        dotState: SessionListDomain.dotState(for: session), isWorking: isWorking(session))
                    Text(SessionListDomain.sessionLabel(for: session))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(SessionListFormat.formatTokens(currentTokenCount(session)))
                        .monospacedDigit()
                        .foregroundStyle(PaiPalette.Semantic.textFaint)

                    // Same trio the web's chat header carries, in the same order: tokens, what
                    // the session has running, then the plan windows.
                    if let counts = currentActivityCounts(session), counts.agents > 0 || counts.tasks > 0 {
                        ActivityBadges(counts: counts)
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                    }

                    if let usage {
                        PlanUsageBadge(usage: usage)
                    }
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(PaiPalette.Semantic.panelBackground)
            }
        }
    }

    private func isWorking(_ session: Session) -> Bool {
        // A discovered session's `working` never fires at all (see `Session.presenceState`), so
        // its spinner is read off `presenceState` instead — already applied onto `session` by
        // `applyLiveStatus` above, same as the session list row.
        if session.discovered == true { return SessionListDomain.isWorking(session) }
        return transcript.liveStatus[sessionID]?.working ?? SessionListDomain.isWorking(session)
    }

    /// The transcript's own live SSE figure wins once it has reported anything for this session;
    /// the session's own persisted count is the fallback for a screen just opened.
    private func currentTokenCount(_ session: Session) -> Int {
        transcript.sessionTokens[sessionID] ?? session.sessionTokens
    }

    /// Same precedence as the token figure: the live stream once it has said anything, the
    /// session's own last-known counts until then.
    private func currentActivityCounts(_ session: Session) -> ActivityCounts? {
        transcript.liveStatus[sessionID]?.activityCounts ?? session.activityCounts
    }

    private var currentSession: Session? {
        sessions.session(withId: sessionID)
    }

    private var navigationTitle: String {
        // Searched, not just synced: a search result older than the loaded pages is not in the
        // synced list at all, and looking only there titles it "Session".
        guard let session = currentSession else { return "Session" }
        return SessionListDomain.sessionHeaderTitle(for: session)
    }
}

/// The account's plan usage: `⏳ 55%/26% 18:20` — the five-hour window, the seven-day window, and
/// when the five-hour one resets. Swift port of `UsageBadge.tsx`, and the same three figures the
/// statusline shows; renders nothing until the agent has reported (the caller already guards on
/// `usage` being non-nil, so this only ever formats real data).
///
/// All three earn their place for different reasons. The five-hour figure is the one that moves
/// while Freddy works. The reset time is what decides whether to start something now or wait —
/// the web keeps it even on its narrowest layout for that reason. The seven-day figure moves
/// slowly but is the one that ends a week early when it runs out, and a percentage with no window
/// named beside it is ambiguous about which of the two it is.
private struct PlanUsageBadge: View {
    let usage: Usage

    private static let amberAt = 50.0
    private static let redAt = 80.0

    var body: some View {
        if usage.fiveHour != nil || usage.sevenDay != nil {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                Text("\(percent(usage.fiveHour))/\(percent(usage.sevenDay))")
                if let resetsAt {
                    Text(resetsAt)
                }
            }
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("plan-usage-badge")
        }
    }

    private func percent(_ window: UsageWindow?) -> String {
        guard let window else { return "–" }
        return "\(Int(window.utilization.rounded()))%"
    }

    /// 🚨 Through `IsoTimestamp`, never a bare `ISO8601DateFormatter` — this field arrives with
    /// six fractional digits and a numeric offset, which the default parser rejects outright.
    /// That rejection is a `nil`, indistinguishable here from the server never having sent a
    /// reset time, which is exactly why nothing reported it while the time was simply missing.
    private var resetsAt: String? {
        guard let iso = usage.fiveHour?.resetsAt, let date = IsoTimestamp.date(from: iso) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var accessibilityLabel: String {
        var parts = [
            "\(percent(usage.fiveHour)) of the 5-hour window", "\(percent(usage.sevenDay)) of the 7-day window",
        ]
        if let resetsAt { parts.append("5-hour window resets at \(resetsAt)") }
        return parts.joined(separator: ", ")
    }

    private var color: Color {
        let highest = max(usage.fiveHour?.utilization ?? 0, usage.sevenDay?.utilization ?? 0)
        if highest >= Self.redAt { return PaiPalette.red500 }
        if highest >= Self.amberAt { return PaiPalette.amber500 }
        return PaiPalette.green500
    }
}

/// Says why the transcript is empty, when it is empty for a reason.
///
/// A failed load, a load still in flight and a conversation with nothing in it all draw the same
/// blank list, so the window's own `bootstrapping`/`bootstrapError` are the only things that can
/// tell them apart — and a screen that cannot tell them apart is confidently wrong rather than
/// honestly unsure, which is the worse of the two.
///
/// Renders nothing at all once messages exist, so it costs the common case nothing.
private struct TranscriptLoadState: View {
    @Environment(TranscriptStore.self) private var transcript
    @Environment(AppEnvironment.self) private var environment
    let sessionID: String

    var body: some View {
        let window = transcript.window(for: sessionID)
        if !TranscriptStore.displayMessages(transcript.messages[sessionID] ?? []).isEmpty {
            EmptyView()
        } else if let error = window.bootstrapError {
            ContentUnavailableView {
                Label("Couldn't load this conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
            .accessibilityIdentifier("transcript-load-error")
        } else if window.bootstrapping {
            ProgressView().accessibilityIdentifier("transcript-loading")
        } else if window.bootstrapped {
            ContentUnavailableView(
                "No messages yet", systemImage: "bubble.left.and.bubble.right",
                description: Text("Anything you send will appear here."))
        }
    }
}

/// The counterpart to `TranscriptLoadState` for the other end of the window — paging in older
/// history rather than the initial load. `window.loadingOlder`/`olderError` were written
/// faithfully by the paging path and read by nothing, so scrolling up showed no indication a
/// fetch was in flight and, on failure, no indication it had stopped — indistinguishable from
/// having reached the true beginning of the conversation either way.
///
/// Pinned to the top edge and deliberately outside the collection view itself: a supplementary
/// header there would need its own height in the row-measurement/anchoring arithmetic the
/// `scrolling` skill governs, and nothing here needs to move a single row to say what is
/// happening above the reader's current position. No retry action — `checkOlderPageTrigger()`
/// already retries the next time the reader scrolls back near the top, which the error text says
/// plainly rather than duplicating with a button that would do the same thing.
private struct TranscriptOlderPageState: View {
    @Environment(TranscriptStore.self) private var transcript
    let sessionID: String

    var body: some View {
        let window = transcript.window(for: sessionID)
        if window.loadingOlder {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading earlier messages…")
            }
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(.bar, in: Capsule())
            .padding(.top, 8)
            .accessibilityIdentifier("transcript-older-loading")
        } else if let error = window.olderError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                Text("Couldn't load earlier messages: \(error). Scroll up to try again.")
            }
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.errorText)
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .background(.bar, in: Capsule())
            .padding(.top, 8)
            .accessibilityIdentifier("transcript-older-error")
        }
    }
}

/// Warns when the transcript's SSE connection sits open and silent while a turn is still expected
/// to produce output — the counterpart to `TerminalScreen`'s status dot, shown only when there is
/// something worth saying rather than as a permanent bar, since the common case (connected,
/// flowing, or genuinely idle between turns) needs no comment. `isProcessing` is what makes this
/// safe to call a stall rather than a guess: without it, a quiet session with nothing to say would
/// read identically to a stream that has gone silent mid-turn.
///
/// An overlay on the transcript, not a sibling row in its `VStack` — a sibling resizes the
/// collection view every time the banner appears or disappears, which is exactly the kind of
/// content jump the `scrolling` skill prohibits outright. An overlay never changes the collection
/// view's own frame, so toggling this costs nothing there regardless of how the threshold below
/// is tuned. `.background(.bar)` is load-bearing now that this floats over scrollable content
/// rather than sitting in its own row with the page ground already behind it.
private struct TranscriptStreamStallBanner: View {
    @Environment(TranscriptStore.self) private var transcript
    let sessionID: String

    /// The backend pings every `SSE_PING_INTERVAL` (15s, `pai_cloud/api.py`, shared by the
    /// transcript and terminal generators) purely to keep the connection alive — a healthy
    /// stream is normally silent between pings, so `idleThreshold` sits just under one interval
    /// and `stallThreshold` clears a full interval plus slack for network jitter. Tuning either
    /// number down has to survive missing at most one ping on an otherwise healthy connection,
    /// or the banner flaps on a schedule instead of only when something is actually wrong —
    /// independent of `TerminalScreen`'s own thresholds, since the two streams are separate
    /// connections and there is no reason their timing has to match.
    private static let idleThreshold: TimeInterval = 12
    private static let stallThreshold: TimeInterval = 30

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
                .background(.bar)
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
