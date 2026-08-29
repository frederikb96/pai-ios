import PAIKit
import SwiftUI

/// The composer's mic control. A stop **square**, deliberately never a second microphone glyph —
/// the source report calls out that two mic icons side by side (this button, and the mute button
/// that takes over the send slot while recording) would be ambiguous, so the state that means
/// "tap to end" always renders as a stop shape instead.
struct VoiceRecorderButton: View {
    let controller: VoiceRecorderController
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            icon
                .font(.system(size: 22))
                .frame(width: 32, height: 32)
        }
        .disabled(
            controller.state == .connecting || controller.state == .stopping
                || !controller.canStart && controller.state == .idle
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("voice-recorder-button")
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.state {
        case .connecting, .stopping:
            ProgressView()
        case .recording:
            Image(systemName: "stop.fill")
                .foregroundStyle(PaiPalette.Semantic.errorText)
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundStyle(
                    controller.canStart ? PaiPalette.Semantic.textSecondary : PaiPalette.Semantic.textFaint)
        }
    }

    private var accessibilityLabel: String {
        switch controller.state {
        case .connecting: "Connecting…"
        case .stopping: "Stopping…"
        case .recording: "Stop recording"
        case .idle: "Start voice recording"
        }
    }
}

/// The red pulsing "Rec" / amber "Muted" indicator shown above the composer while a take is in
/// progress — the same live feedback `MessageInput.tsx` renders beside the offline-agent notice.
struct VoiceRecordingIndicator: View {
    let controller: VoiceRecorderController

    var body: some View {
        if controller.state == .recording || controller.state == .connecting || controller.state == .stopping {
            HStack(spacing: 6) {
                Circle()
                    .fill(controller.isMuted ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.errorText)
                    .frame(width: 8, height: 8)
                Text(controller.isMuted ? "Muted" : "Rec")
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(
                        controller.isMuted ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.errorText)
            }
            .accessibilityIdentifier("voice-recording-indicator")
        }
    }
}

/// Replaces the send button's slot while recording — sending mid-take is deliberately impossible,
/// since it would post half a sentence and leave the rest arriving into an empty composer.
struct MuteButton: View {
    let controller: VoiceRecorderController
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Image(systemName: controller.isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 20))
                .frame(width: 36, height: 36)
                .foregroundStyle(.white)
                .background(controller.isMuted ? PaiPalette.Semantic.warningText : PaiPalette.primary500)
                .clipShape(Circle())
        }
        .accessibilityLabel(controller.isMuted ? "Unmute" : "Mute")
        .accessibilityAddTraits(controller.isMuted ? [.isSelected] : [])
        .accessibilityIdentifier("voice-mute-button")
    }
}
