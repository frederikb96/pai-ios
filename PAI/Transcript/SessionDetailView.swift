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
    @State private var usage: Usage?

    let sessionID: String

    var body: some View {
        Group {
            if let connection = environment.connection {
                VStack(spacing: 0) {
                    headerStrip
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
        .task {
            // A route restored after relaunch, or a deep link, can name a session outside every
            // page the list has loaded — this is what makes it resolvable regardless.
            await sessions.ensureSessionLoaded(id: sessionID)
        }
        // Routes the transcript's own live SSE `status` event into the session list the moment
        // it changes, so the list (and this header, which reads through the same store) reflect
        // it while this screen is open rather than waiting for the 10s poll — see
        // `TranscriptStore.liveStatus`'s doc comment. One mutator, one call site.
        .onChange(of: transcript.liveStatus[sessionID]) { _, newValue in
            guard let newValue else { return }
            sessions.applyLiveStatus(
                sessionId: sessionID, state: newValue.state, blocker: newValue.blocker, working: newValue.working,
                activityCounts: newValue.activityCounts
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
        transcript.liveStatus[sessionID]?.working ?? SessionListDomain.isWorking(session)
    }

    /// The transcript's own live SSE figure wins once it has reported anything for this session;
    /// the session's own persisted count is the fallback for a screen just opened.
    private func currentTokenCount(_ session: Session) -> Int {
        transcript.sessionTokens[sessionID] ?? session.sessionTokens
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

/// The account's plan usage — five-hour window, seven-day window, and when the five-hour one
/// resets. Swift port of `UsageBadge.tsx`; renders nothing until the agent has reported (the
/// caller already guards on `usage` being non-nil, so this only ever formats real data).
private struct PlanUsageBadge: View {
    let usage: Usage

    private static let amberAt = 50.0
    private static let redAt = 80.0

    var body: some View {
        if usage.fiveHour != nil || usage.sevenDay != nil {
            HStack(spacing: 4) {
                Image(systemName: "hourglass")
                Text(fiveHourText)
                if let resetsAt {
                    Text(resetsAt)
                }
            }
            .monospacedDigit()
            .foregroundStyle(color)
            .accessibilityIdentifier("plan-usage-badge")
        }
    }

    private var fiveHourText: String {
        guard let five = usage.fiveHour else { return "–" }
        return "\(Int(five.utilization.rounded()))%"
    }

    private var resetsAt: String? {
        guard let iso = usage.fiveHour?.resetsAt, let date = Self.parser.date(from: iso) else { return nil }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private var color: Color {
        let highest = max(usage.fiveHour?.utilization ?? 0, usage.sevenDay?.utilization ?? 0)
        if highest >= Self.redAt { return PaiPalette.red500 }
        if highest >= Self.amberAt { return PaiPalette.amber500 }
        return PaiPalette.green500
    }

    private static let parser = ISO8601DateFormatter()

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
    }}
