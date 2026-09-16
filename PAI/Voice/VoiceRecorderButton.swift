import PAIKit
import SwiftUI
import UIKit

/// The composer's mic control. A stop **square**, deliberately never a second microphone glyph —
/// the source report calls out that two mic icons side by side (this button, and the mute button
/// that takes over the send slot while recording) would be ambiguous, so the state that means
/// "tap to end" always renders as a stop shape instead.
struct VoiceRecorderButton: View {
    let controller: VoiceRecorderController
    /// Whether a running take belongs to the composer this button sits in. The recorder is
    /// app-wide and the microphone is exclusive, so a button in some other composer must not
    /// offer to stop a take it does not own — it renders an unavailable microphone instead, which
    /// is what the situation actually is.
    var isMine: Bool = true
    /// A long press on the same control, offered alongside the tap — the composer's own reach
    /// into call mode. `nil` everywhere else (the new-session composer has no call mode to
    /// reach), which renders exactly the plain tap-only button this always was.
    ///
    /// Never attached as a plain SwiftUI `.onLongPressGesture`/`.simultaneousGesture` on top of
    /// `Button` — that combination is documented to double-fire, the long press *and* the
    /// button's own tap action both, since SwiftUI has no way to make its own gesture require a
    /// competing one to fail. `UILongPressGestureRecognizer.require(toFail:)` does, so a long
    /// press is only ever offered through `TapAndLongPressCatcher`, a UIKit-backed layer over the
    /// button rather than a SwiftUI gesture modifier on it.
    var onLongPress: (() -> Void)? = nil
    var longPressMinimumDuration: TimeInterval = 0.5
    var onTap: () -> Void

    private var displayState: VoiceRecordingState {
        isMine ? controller.state : .idle
    }

    private var canStart: Bool {
        isMine && controller.canStart
    }

    private var isDisabled: Bool {
        displayState == .connecting || displayState == .stopping
            || !canStart && displayState == .idle
    }

    var body: some View {
        let button =
            Button(action: onTap) {
                icon
                    .font(.system(size: 22))
                    .frame(width: 32, height: 32)
            }
            .disabled(isDisabled)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier("voice-recorder-button")

        if let onLongPress {
            // The button underneath still renders (icon, dimming, accessibility) but never
            // itself receives the touch — the catcher owns the gesture and drives `onTap` too, so
            // there is exactly one path to either action, not two racing ones.
            button
                .allowsHitTesting(false)
                .overlay(
                    TapAndLongPressCatcher(
                        isEnabled: !isDisabled,
                        minimumLongPressDuration: longPressMinimumDuration,
                        onTap: onTap,
                        onLongPress: onLongPress)
                )
        } else {
            button
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch displayState {
        case .connecting, .stopping, .reconnecting:
            ProgressView()
        case .recording:
            Image(systemName: "stop.fill")
                .foregroundStyle(PaiPalette.Semantic.errorText)
        case .paused:
            // Still shows a stop shape, not a pause glyph — tapping it must still end the take
            // (`VoiceRecordingSession.stop` already accepts `.paused`), and the pulsing indicator
            // above the composer is what actually communicates the paused state.
            Image(systemName: "stop.fill")
                .foregroundStyle(PaiPalette.Semantic.warningText)
        case .transcriptionStopped:
            // Still capturing to disk, still a stop shape — the take is not over, only live
            // transcription is; tapping ends it the same as every other non-idle state.
            Image(systemName: "stop.fill")
                .foregroundStyle(PaiPalette.Semantic.warningText)
        case .idle:
            Image(systemName: "mic.fill")
                .foregroundStyle(canStart ? PaiPalette.Semantic.textSecondary : PaiPalette.Semantic.textFaint)
        }
    }

    private var accessibilityLabel: String {
        switch displayState {
        case .connecting: "Connecting…"
        case .stopping: "Stopping…"
        case .reconnecting: "Reconnecting…"
        case .recording: "Stop recording"
        case .paused: "Paused — stop recording"
        case .transcriptionStopped: "Transcription stopped — recording continues"
        case .idle: "Start voice recording"
        }
    }
}

/// The red pulsing "Rec" / amber "Muted" indicator shown above the composer while a take is in
/// progress — the same live feedback `MessageInput.tsx` renders beside the offline-agent notice.
///
/// `.paused`/`.reconnecting` render their own label rather than folding into "Rec" — the entire
/// point of a durable recording is that Freddy is not meant to be staring at this, but on the one
/// occasion he does glance at it, "Rec" while the mic is actually off (paused) would be exactly
/// the false liveness claim the design this replaces was built to avoid.
struct VoiceRecordingIndicator: View {
    let controller: VoiceRecorderController

    var body: some View {
        if let label {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(label)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(color)
            }
            .accessibilityIdentifier("voice-recording-indicator")
        }
    }

    private var label: String? {
        switch controller.state {
        case .recording, .stopping: controller.isMuted ? "Muted" : "Rec"
        case .connecting: "Connecting…"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting…"
        case .transcriptionStopped: "Not transcribing"
        case .idle: nil
        }
    }

    private var color: Color {
        switch controller.state {
        case .paused, .reconnecting, .transcriptionStopped: PaiPalette.Semantic.warningText
        default: controller.isMuted ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.errorText
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

/// A transparent touch-catching layer that tells a tap and a long press apart reliably — see
/// `VoiceRecorderButton.onLongPress`'s own doc comment for why this exists rather than a plain
/// SwiftUI gesture modifier. `longPress.require(toFail: tap)` is the one thing that actually
/// prevents the double fire: the long press only succeeds once the tap has already failed to
/// recognize (i.e., the touch was held past the long-press threshold), so exactly one of the two
/// closures below ever runs per touch, never both.
@MainActor
private struct TapAndLongPressCatcher: UIViewRepresentable {
    var isEnabled: Bool
    var minimumLongPressDuration: TimeInterval
    var onTap: () -> Void
    var onLongPress: () -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap))
        let longPress = UILongPressGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleLongPress))
        longPress.minimumPressDuration = minimumLongPressDuration
        longPress.require(toFail: tap)
        view.addGestureRecognizer(tap)
        view.addGestureRecognizer(longPress)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        uiView.isUserInteractionEnabled = isEnabled
        context.coordinator.onTap = onTap
        context.coordinator.onLongPress = onLongPress
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onLongPress: onLongPress)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onTap: () -> Void
        var onLongPress: () -> Void

        init(onTap: @escaping () -> Void, onLongPress: @escaping () -> Void) {
            self.onTap = onTap
            self.onLongPress = onLongPress
        }

        @objc func handleTap() { onTap() }

        /// One of `.began`/`.changed`/`.ended`/`.cancelled` fires per recognized press —
        /// `.began` is the moment the hold has already lasted `minimumPressDuration`, which is
        /// the point equivalent to `.onLongPressGesture`'s own `onEnded` firing.
        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onLongPress()
        }
    }
}
