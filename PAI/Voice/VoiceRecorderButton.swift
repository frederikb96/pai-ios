import PAIKit
import SwiftUI

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
    /// Overrides `controller.canStart`'s own gate on an idle tap — `nil` keeps the ordinary
    /// behavior (`CreateSessionView`'s own mic, which has no session yet to hand a running take
    /// or call over to). The composer passes an explicit value so a tap can take over a take or a
    /// call running elsewhere, which `controller.canStart` alone always refuses.
    var canStartOverride: Bool?
    /// Starts a take in the given mode: a long press on the idle microphone starts
    /// `alternateMode`. `nil` leaves the long press inert — a plain tap starts the default mode
    /// (`onTap`'s own choice).
    var onStart: ((VoiceSttMode) -> Void)? = nil
    /// The mode a long press starts: whichever one the tap does not (`SettingsStore.alternateRecordingMode`).
    var alternateMode: VoiceSttMode = .batch
    var onTap: () -> Void

    private var displayState: VoiceRecordingState {
        isMine ? controller.state : .idle
    }

    private var canStart: Bool {
        Self.canStart(controller: controller, isMine: isMine, canStartOverride: canStartOverride)
    }

    private static func canStart(
        controller: VoiceRecorderController, isMine: Bool, canStartOverride: Bool?
    ) -> Bool {
        canStartOverride ?? (isMine && controller.canStart)
    }

    /// Whether this button, drawn with the same arguments, is an idle microphone a press can
    /// start a take from — what decides if the plus menu offers its own way to the alternate mode.
    static func offersStart(
        controller: VoiceRecorderController, isMine: Bool, canStartOverride: Bool?
    ) -> Bool {
        (isMine ? controller.state : .idle) == .idle
            && canStart(controller: controller, isMine: isMine, canStartOverride: canStartOverride)
    }

    var body: some View {
        Button(action: onTap) {
            icon
                .font(.system(size: 22))
                .frame(width: 32, height: 32)
        }
        // 🚨 `.connecting` stays tappable, deliberately — a connection attempt that cannot reach
        // the backend used to leave no way out but waiting it out. Tapping it now cancels the
        // uplink's own attempt (`VoiceUplinkSession.stop()` guards only on `!= .idle`, so this
        // reaches it from `.connecting` too) and returns to idle, on every client. Never cancels
        // the recording itself — the recorder has no idea a connection exists at all.
        //
        // `.stopping` (Finishing) is tappable too: a tap stops waiting for `take_done` or the
        // deadline. Nothing is lost — the server holds the take and its words still come back.
        .disabled(!canStart && displayState == .idle)
        .modifier(
            AlternateLongPress(mode: alternateMode, onStart: displayState == .idle && canStart ? onStart : nil)
        )
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("voice-recorder-button")
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
        case .connecting: "Connecting… Tap to cancel"
        case .stopping: "Finishing… Tap to stop now"
        case .reconnecting: "Reconnecting… Tap to cancel"
        case .recording: "Stop recording"
        case .paused: "Paused — stop recording"
        case .transcriptionStopped: "Transcription stopped — recording continues"
        case .idle: "Start voice recording"
        }
    }
}

/// A long press on an idle microphone starts the recording mode a tap does not, straight away.
/// Batch records while it runs and puts the whole take's transcript in afterwards — no words
/// appear while speaking, nothing is billed until the end, and a bad connection costs nothing but
/// the wait; the composer stays open for typing meanwhile. Live streams the words in as they are
/// spoken.
///
/// `.highPriorityGesture`, as on the session list's rows: a bare long-press modifier competes with
/// the button's own tap and can fire both, which here would start a take and stop it on release.
/// A press released before the duration fails cleanly and leaves the tap to the button.
private struct AlternateLongPress: ViewModifier {
    let mode: VoiceSttMode
    let onStart: ((VoiceSttMode) -> Void)?

    func body(content: Content) -> some View {
        if let onStart {
            content
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.45)
                        .onEnded { _ in onStart(mode) }
                )
                .accessibilityAction(named: mode == .batch ? "Dictate in batch" : "Dictate live") { onStart(mode) }
        } else {
            content
        }
    }
}

/// Shown above a composer whose batch take is being transcribed on the server — its words land
/// in the field by themselves, and a Send made meanwhile waits for them — or whose batch take is
/// stuck, which a Send does not wait for.
struct BatchTranscribingLine: View {
    var isStuck = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isStuck ? "exclamationmark.triangle" : "tray.and.arrow.up")
                .font(.system(size: 11))
            Text(text)
                .font(PaiTypography.caption.font)
        }
        .foregroundStyle(isStuck ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.textSecondary)
        .accessibilityIdentifier(isStuck ? "voice-batch-stuck" : "voice-batch-transcribing")
    }

    private var text: String {
        isStuck
            ? "Batch dictation stuck — see Past Recordings; Send does not wait for it"
            : "Batch dictation transcribing — Send waits for it"
    }
}

/// The red pulsing "Rec" / amber "Muted" indicator shown above the composer while a take is in
/// progress — the same live feedback `MessageInput.tsx` renders beside the offline-agent notice.
///
/// `.paused`/`.reconnecting` render their own label rather than folding into "Rec" — the entire
/// point of a durable recording is that the user is not meant to be staring at this, but on the one
/// occasion the user does glance at it, "Rec" while the mic is actually off (paused) would be exactly
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
        case .recording: recordingLabel
        // Finishing, never "Rec" — the microphone has genuinely stopped by now, and claiming
        // otherwise is exactly the false-liveness reading `.paused`'s own case already avoids.
        case .stopping: "Finishing…"
        case .connecting: "Connecting…"
        case .paused: "Paused"
        case .reconnecting: "Reconnecting…"
        case .transcriptionStopped: "Not transcribing"
        case .idle: nil
        }
    }

    /// A plain property rather than an inline chain in the `switch`, which the type checker
    /// handles poorly inside a view builder.
    private var recordingLabel: String {
        let base = controller.isMuted ? "Muted" : (controller.isWithholding ? "Rec · holding silence" : "Rec")
        return controller.activeSttMode == .batch ? "\(base) · Batch" : base
    }

    private var color: Color {
        switch controller.state {
        case .paused, .reconnecting, .transcriptionStopped, .stopping: PaiPalette.Semantic.warningText
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
