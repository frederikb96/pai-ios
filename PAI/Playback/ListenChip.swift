import PAIKit
import SwiftUI

/// The control under every assistant reply that reads it aloud. Always drawn for a reply with
/// something to read (its height is part of the measured row, so switching playback on never moves
/// a row), and fixed in height: `TranscriptRowMetrics.listenChipHeight`.
struct ListenChip: View {
    let sessionId: String
    let messageId: Int
    let content: String

    private var controller: PlaybackController { .shared }

    var body: some View {
        let store = controller.store
        let current = store.current?.messageId == messageId ? store.current : nil
        let heard = store.heard.contains(messageId)
        HStack {
            Button {
                controller.playReply(
                    sessionId: sessionId, messageId: messageId, title: PlaybackModel.snippet(ofContent: content))
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: (current?.isPlayingOrStarting ?? false) ? "pause.fill" : "play.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(label(current: current, heard: heard))
                        .font(PaiTypography.caption.font)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(height: TranscriptRowMetrics.listenChipHeight)
                .foregroundStyle(current != nil ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textMuted)
                .background(
                    current != nil ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                    in: Capsule()
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel(current: current))
            .accessibilityIdentifier("listen-chip")
            Spacer(minLength: 0)
        }
        .frame(height: TranscriptRowMetrics.listenChipHeight)
    }

    private func label(current: PlaybackCurrent?, heard: Bool) -> String {
        guard let current else { return heard ? "Listen again" : "Listen" }
        if current.status == .error { return "Try again" }
        if current.durationMs > 0 {
            return "\(PlaybackModel.formatClock(current.positionMs)) / \(PlaybackModel.formatClock(current.durationMs))"
        }
        return "Loading…"
    }

    private func accessibilityLabel(current: PlaybackCurrent?) -> String {
        guard let current else { return "Listen to this reply" }
        return current.isPlayingOrStarting ? "Pause this reply" : "Resume this reply"
    }
}
