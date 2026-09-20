import PAIKit
import SwiftUI

/// Says that a call is up, from anywhere in the app, and takes one tap to get back to it.
///
/// This exists because the call now outlives its screen. Nothing ends a call on its own any more
/// — the quiet phase has no timeout, a quiet take only drops back to it, and the only stop is the
/// backend's own absolute ceiling hours later — so a screen backed out of leaves a live,
/// metered microphone with nothing on screen saying so. The system's own in-call bar is the
/// precedent, and the reason it is a permanent strip rather than a badge somewhere: it has to be
/// impossible to miss from a screen Freddy navigated to for some entirely unrelated reason.
///
/// Draws nothing at all while the voice screen itself is on top, where it would only repeat what
/// is already filling the screen.
struct ComputerCallBar: View {
    let controller: ComputerCallController
    let sessions: SessionListStore
    let isShowingCall: Bool
    let onTap: () -> Void

    var body: some View {
        if controller.isLive, !isShowingCall {
            Button(action: onTap) {
                HStack(spacing: 8) {
                    Image(systemName: "waveform")
                        .font(.system(size: 13, weight: .semibold))
                    Text(label)
                        .font(PaiTypography.caption.font)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("Return")
                        .font(PaiTypography.caption.font)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .background(PaiPalette.primary500)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("computer-call-bar")
            .accessibilityLabel("\(label). Return to the call.")
        }
    }

    private var label: String {
        switch presentation.face {
        case .computer:
            return "On a call with Computer"
        case .call(_, let name):
            return name.map { "On a call in \($0)" } ?? "On a call in a session"
        }
    }

    private var presentation: ComputerCallPresentation {
        ComputerCallPresentation.make(
            connectionState: controller.session.connectionState,
            busOwner: controller.session.busOwner,
            phase: controller.session.phase,
            sessionId: controller.session.sessionId,
            sessionName: controller.session.sessionId
                .flatMap { sessions.session(withId: $0) }
                .map { SessionListFormat.displayTitle(for: $0) },
            isSpeaking: controller.isSpeaking
        )
    }
}
