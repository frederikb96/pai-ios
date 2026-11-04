import PAIKit
import SwiftUI

/// The autoplay switch of one session: it spends credits unattended, so it is a switch of its own
/// and never a setting that follows the person from session to session.
struct AutoplaySwitch: View {
    let sessionId: String
    private var store: PlaybackStore { PlaybackController.shared.store }

    var body: some View {
        let on = store.modes[sessionId]?.autoplay ?? false
        Button {
            store.setAutoplay(sessionId, !on)
        } label: {
            Text("Autoplay \(on ? "on" : "off")")
                .font(PaiTypography.captionEmphasized.font)
                .padding(.horizontal, 12)
                .frame(minHeight: 32)
                .foregroundStyle(on ? Color.white : PaiPalette.Semantic.textSecondary)
                .background(on ? PaiPalette.primary500 : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(on ? PaiPalette.primary500 : PaiPalette.Semantic.borderStrong))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityIdentifier("playback-autoplay")
    }
}

/// The mini player docked above the composer of a session with playback on. Shows the reply in
/// hand with play/pause and ±10 s, or, while nothing plays, that playback is on and the autoplay
/// switch. The hairline on its top edge is the position in the reply.
struct PlaybackBar: View {
    let sessionId: String

    private var controller: PlaybackController { .shared }

    var body: some View {
        let store = controller.store
        if store.isOn(sessionId) {
            let current = store.current?.sessionId == sessionId ? store.current : nil
            HStack(spacing: 6) {
                if let current {
                    playing(current)
                } else {
                    idle
                }
                Button {
                    store.sheetOpen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .frame(width: 40, height: 40)
                }
                .buttonStyle(.plain)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .accessibilityLabel("Open player")
                .accessibilityIdentifier("playback-open-sheet")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .top) { hairline(current) }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Playback")
            .accessibilityIdentifier("playback-bar")
            .fixtureFact("playbackBar", current.map { "\($0.status)" } ?? "idle")
        }
    }

    private func hairline(_ current: PlaybackCurrent?) -> some View {
        GeometryReader { proxy in
            let progress =
                (current?.durationMs ?? 0) > 0 ? min(Double(current!.positionMs) / Double(current!.durationMs), 1) : 0
            Rectangle().fill(PaiPalette.primary500).frame(width: proxy.size.width * progress, height: 2)
        }
        .frame(height: 2)
    }

    private func playing(_ current: PlaybackCurrent) -> some View {
        HStack(spacing: 6) {
            Button {
                controller.toggle()
            } label: {
                Image(systemName: current.isPlayingOrStarting ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(PaiPalette.primary500, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(current.isPlayingOrStarting ? "Pause" : "Play")
            .accessibilityIdentifier("playback-toggle")
            VStack(alignment: .leading, spacing: 2) {
                Text(current.title)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
                line(current)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            skipButton(systemImage: "gobackward.10", label: "Back 10 seconds", by: -PlaybackModel.skipMs)
            skipButton(systemImage: "goforward.10", label: "Forward 10 seconds", by: PlaybackModel.skipMs)
        }
    }

    @ViewBuilder
    private func line(_ current: PlaybackCurrent) -> some View {
        if let notice = current.notice, current.status == .error || !notice.isEmpty {
            Text(notice)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.warningText)
                .lineLimit(2)
        } else if let voiceNote = current.voiceNote {
            Text(voiceNote)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .lineLimit(2)
                .accessibilityIdentifier("playback-voice-note")
        } else {
            Text(
                current.status == .loading && current.durationMs == 0
                    ? "Loading…"
                    : "\(PlaybackModel.formatClock(current.positionMs)) / \(PlaybackModel.formatClock(current.durationMs))"
            )
            .font(PaiTypography.caption.font)
            .monospacedDigit()
            .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
    }

    private func skipButton(systemImage: String, label: String, by delta: Int) -> some View {
        Button {
            controller.skip(byMs: delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PaiPalette.Semantic.textSecondary)
        .accessibilityLabel(label)
    }

    private var idle: some View {
        HStack(spacing: 8) {
            Image(systemName: "headphones")
                .font(.system(size: 18))
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("Playback is on")
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Text("Tap Listen under a reply")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            AutoplaySwitch(sessionId: sessionId)
        }
    }
}
