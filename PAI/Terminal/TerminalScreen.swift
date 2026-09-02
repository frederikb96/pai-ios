import Foundation
import PAIKit
import SwiftUI

/// A session's terminal — the escape hatch for whatever the session API cannot express.
///
/// The pane is fixed at 200 columns (`TerminalPaneGeometry`) with no resize endpoint, so a phone
/// cannot make it fit — horizontal scroll is the honest answer rather than reflowing. Every frame
/// the agent sends is a complete repaint of a 50-row pane, never a diff, so there is never more
/// than 50 lines on screen at once: small enough that rendering every row plainly is correct, and
/// none of the virtualization a longer list would need applies here.
///
/// Paging through what the agent has already captured is a request the app can make without a
/// keyboard (`POST .../terminal/scroll`), so the status bar offers that regardless of whether the
/// input field below is focused. Typing, the arrows, Escape and a Control modifier all go through
/// `TerminalInputField` — see its own doc comment for why the field is visible rather than a
/// hidden keyboard-summoning trick, and `TerminalKeyBytes` for the byte sequences each of these
/// sends. No backend change was needed for any of it: `terminal/input` already takes raw bytes.
struct TerminalScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalStreamClientFactory) private var makeStreamClient

    let sessionID: String

    @State private var paneState: TerminalPaneState = .initial
    @State private var isConnected = false
    @State private var activity = StreamActivity()
    @State private var client: PaiTerminalStreamClient?
    /// Not auto-focused on open — this is a screen someone reaches deliberately when something
    /// has gone wrong, not a composer waiting for text, and popping the keyboard up over half the
    /// pane the instant it appears would cover the very thing they came to read.
    @State private var isInputFocused = false

    /// The backend pings every `SSE_PING_INTERVAL` (15s, `pai_cloud/api.py`, shared by the
    /// transcript and terminal generators) purely to keep the connection alive, so a healthy
    /// stream is normally silent between pings. Below `idleThreshold`, quiet reads as normal and
    /// the status bar says nothing about it; `stallThreshold` clears a full ping interval plus
    /// slack for jitter before flagging anything, and stays under the client's own reconnect
    /// timeout so this warns well before that fires. See `StreamActivity`.
    private static let idleThreshold: TimeInterval = 12
    private static let stallThreshold: TimeInterval = 30

    var body: some View {
        Group {
            if makeStreamClient == nil {
                unavailable
            } else {
                VStack(spacing: 0) {
                    statusBar
                    Divider()
                    paneView
                    Divider()
                    inputField
                }
            }
        }
        .background(TerminalColorMapping.background(for: colorScheme))
        .navigationTitle("Terminal")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("terminal-screen")
        .task(id: sessionID) { connect() }
        .onDisappear {
            client?.disconnect()
            client = nil
        }
    }

    private var unavailable: some View {
        ContentUnavailableView(
            "Terminal Unavailable",
            systemImage: "terminal",
            description: Text("This session isn't connected to a live stream.")
        )
        .accessibilityIdentifier("terminal-unavailable")
    }

    // MARK: - Status bar

    /// Mirrors `TerminalView.tsx`'s own status row: a dot for connection/live state, "Jump to
    /// Live" only while scrolled back, and paging controls in place of the web's wheel/swipe/
    /// pinch gestures — a phone has neither, and reproducing threshold-based gesture accumulation
    /// for a read-only view is more risk than the feature is worth.
    ///
    /// Wrapped in a `TimelineView` so "quiet for how long" keeps counting up while the screen sits
    /// open — `activity`'s own state only changes on a callback, but the elapsed time it reports
    /// does not, and a dot that only updates when a frame happens to arrive is the same
    /// confidently-wrong "Live" this exists to replace.
    private var statusBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let activityState = activity.state(
                now: context.date, idleThreshold: Self.idleThreshold, stallThreshold: Self.stallThreshold)
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor(activityState))
                    .frame(width: 8, height: 8)
                Text(statusLabel(activityState))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)

                Spacer()

                if isConnected && !paneState.live {
                    Button("Jump to Live") { requestScroll(.live) }
                        .font(PaiTypography.captionEmphasized.font)
                        .accessibilityIdentifier("terminal-jump-to-live")
                }

                Button {
                    requestScroll(.up)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityIdentifier("terminal-scroll-up")

                Button {
                    requestScroll(.down)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityIdentifier("terminal-scroll-down")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .accessibilityIdentifier("terminal-status-bar")
        }
    }

    /// Connecting and disconnected share one grey, pulsing-in-spirit dot, same as the web's
    /// `!connected` case — there is no separate "gave up" state, since the client retries with
    /// backoff until the view disconnects it. Idle stays green: quiet alone is not a problem, and
    /// the label already says so. Stalled turns amber even at the live edge — a green dot with
    /// nothing arriving for this long is the exact failure this status bar exists to rule out.
    private func statusColor(_ activityState: StreamActivityState) -> Color {
        guard isConnected else { return PaiPalette.surface400 }
        guard paneState.live else { return PaiPalette.amber500 }
        if case .stalled = activityState { return PaiPalette.amber500 }
        return PaiPalette.green500
    }

    /// "Live" alone once a frame has arrived recently; past `idleThreshold` the elapsed time
    /// itself is what tells "flowing" and "quiet" apart, whether or not that quiet is a problem.
    private func statusLabel(_ activityState: StreamActivityState) -> String {
        guard isConnected else { return "Connecting…" }
        guard paneState.live else { return "Scrolled back" }
        switch activityState {
        case .receiving, .disconnected:
            return "Live"
        case .idle(let elapsed), .stalled(let elapsed):
            return "Live · \(Self.formatted(elapsed)) ago"
        }
    }

    private static func formatted(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        return seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
    }

    // MARK: - Pane

    private var paneView: some View {
        ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(paneState.screen.lines.enumerated()), id: \.offset) { _, line in
                    lineView(line)
                }
            }
            .padding(8)
        }
        .accessibilityIdentifier("terminal-pane")
    }

    private func lineView(_ line: TerminalLine) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(line.runs.enumerated()), id: \.offset) { _, run in
                runView(run)
            }
        }
    }

    /// One run per `Text`, not a single concatenated line: SwiftUI's `Text + Text` operator keeps
    /// per-segment foreground/weight/style, but not a per-segment background — an `HStack` of
    /// plain views is what lets an SGR background color render at all. The pane already scrolls
    /// horizontally instead of wrapping, so an `HStack` costs nothing extra here.
    private func runView(_ run: TerminalRun) -> some View {
        Text(run.text.isEmpty ? " " : run.text)
            .font(PaiTypography.monoLabel.font)
            .fontWeight(run.style.bold ? .bold : .regular)
            .italic(run.style.italic)
            .underline(run.style.underline)
            .foregroundStyle(foregroundColor(for: run.style))
            .background(backgroundColor(for: run.style))
    }

    private func foregroundColor(for style: TerminalStyle) -> Color {
        let base =
            style.foreground.map(TerminalColorMapping.resolve)
            ?? TerminalColorMapping.foreground(for: colorScheme)
        // SGR "dim" has no SwiftUI equivalent on `Text`; blending the resolved color toward
        // transparent reads the same as a real terminal's dimmed text without needing a second,
        // separately-maintained dim palette.
        return style.dim ? base.opacity(0.6) : base
    }

    private func backgroundColor(for style: TerminalStyle) -> Color {
        style.background.map(TerminalColorMapping.resolve) ?? .clear
    }

    // MARK: - Input

    private var inputField: some View {
        TerminalInputField(
            isFocused: isInputFocused,
            onSendImmediate: { sendRawInput($0) },
            onSendLineBreak: { draft in sendRawInput(draft + TerminalKeyBytes.submit, literal: true) },
            onSubmit: { draft in sendRawInput(draft + TerminalKeyBytes.submit) },
            onFocus: { isInputFocused = true }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func sendRawInput(_ data: String, literal: Bool = false) {
        guard let apiClient = environment.connection?.apiClient else { return }
        Task {
            try? await apiClient.sendTerminalInput(sessionId: sessionID, data: data, literal: literal)
        }
    }

    // MARK: - Streaming

    private func connect() {
        guard let makeStreamClient else { return }
        paneState = .initial
        isConnected = false
        activity = StreamActivity()
        let newClient = makeStreamClient(
            sessionID,
            PaiTerminalStreamClient.Callbacks(
                onFrame: { chunk, live in
                    paneState = paneState.applying(TerminalFrameChunk(data: chunk, live: live))
                    activity.recordEvent(at: Date())
                },
                onConnected: {
                    isConnected = true
                    activity.recordConnected(at: Date())
                },
                onDisconnected: {
                    isConnected = false
                    activity.recordDisconnected()
                }
            )
        )
        client = newClient
        newClient.connect()
    }

    private func requestScroll(_ direction: PaiTerminalScrollDirection) {
        guard let apiClient = environment.connection?.apiClient else { return }
        Task {
            try? await apiClient.sendTerminalScroll(sessionId: sessionID, direction: direction)
        }
    }
}
