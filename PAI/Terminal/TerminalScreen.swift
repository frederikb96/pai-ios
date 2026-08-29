import PAIKit
import SwiftUI

/// A session's terminal, read-only.
///
/// The pane is fixed at 200 columns (`TerminalPaneGeometry`) with no resize endpoint, so a phone
/// cannot make it fit — horizontal scroll is the honest answer rather than reflowing. Every frame
/// the agent sends is a complete repaint of a 50-row pane, never a diff, so there is never more
/// than 50 lines on screen at once: small enough that rendering every row plainly is correct, and
/// none of the virtualization a longer list would need applies here.
///
/// Interactive input is deferred — the web relies on a hardware keyboard for PageUp/PageDown/
/// Ctrl-C, which a phone has none of, and nobody has built the on-screen key row that would
/// replace it. Paging through what the agent has already captured is still a request the app can
/// make without a keyboard (`POST .../terminal/scroll`), so the toolbar offers that.
struct TerminalScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.terminalStreamClientFactory) private var makeStreamClient

    let sessionID: String

    @State private var paneState: TerminalPaneState = .initial
    @State private var isConnected = false
    @State private var client: PaiTerminalStreamClient?

    var body: some View {
        Group {
            if makeStreamClient == nil {
                unavailable
            } else {
                VStack(spacing: 0) {
                    statusBar
                    Divider()
                    paneView
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
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusLabel)
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

    /// Connecting and disconnected share one grey, pulsing-in-spirit dot, same as the web's
    /// `!connected` case — there is no separate "gave up" state, since the client retries with
    /// backoff until the view disconnects it.
    private var statusColor: Color {
        guard isConnected else { return PaiPalette.surface400 }
        return paneState.live ? PaiPalette.green500 : PaiPalette.amber500
    }

    private var statusLabel: String {
        guard isConnected else { return "Connecting…" }
        return paneState.live ? "Live" : "Scrolled back"
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

    // MARK: - Streaming

    private func connect() {
        guard let makeStreamClient else { return }
        paneState = .initial
        isConnected = false
        let newClient = makeStreamClient(
            sessionID,
            PaiTerminalStreamClient.Callbacks(
                onFrame: { chunk, live in
                    paneState = paneState.applying(TerminalFrameChunk(data: chunk, live: live))
                },
                onConnected: { isConnected = true },
                onDisconnected: { isConnected = false }
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
