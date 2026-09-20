import PAIKit
import SwiftUI

/// The always-reachable voice agent, reached from the full-width Computer tile on
/// `QuickActionsScreen`. Freddy's own acceptance line: tap the tile, speak to Computer, hear it
/// answer, and end it.
///
/// Owns its own `ComputerCallController` rather than reaching one off `AppEnvironment` — unlike
/// `VoiceRecorderController`, nothing about a Computer call needs to survive the screen that
/// started it (no draft is being written that another device could be watching fill in), so the
/// controller's lifetime matches this view's exactly: built when it appears, torn down when it
/// disappears.
///
/// A full-screen cover rather than a sheet: a live microphone deserves the same undivided
/// attention a phone call gets, and `.interactiveDismissDisabled()` is what stops a swipe from
/// silently abandoning the call without ever sending `bye` — `onDisappear` is the only path that
/// ends it, and a bare swipe-to-dismiss would bypass that.
struct ComputerCallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var controller: ComputerCallController?

    var body: some View {
        if let controller {
            content(controller: controller)
        } else {
            // Unreachable in practice — the tile that opens this screen only exists once signed
            // in — but a blank screen with no way out would be worse than dismissing outright if
            // it ever were.
            Color.clear
                .task {
                    guard let connection = environment.connection else {
                        dismiss()
                        return
                    }
                    let made = ComputerCallController(
                        requestFactory: connection.requestFactory,
                        authToken: { KeychainTokenStore().read() },
                        toasts: connection.toasts
                    )
                    controller = made
                    await made.start()
                }
        }
    }

    @ViewBuilder
    private func content(controller: ComputerCallController) -> some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(PaiPalette.primary500)
                .accessibilityHidden(true)
            Text("Computer")
                .font(PaiTypography.screenTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Text(statusText(controller: controller))
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("computer-call-status")
            if let failure = controller.setupFailure {
                Text(failure)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Button {
                Task {
                    await controller.end()
                    dismiss()
                }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(PaiPalette.red500, in: Circle())
            }
            .accessibilityLabel("End call with Computer")
            .accessibilityIdentifier("computer-call-end")
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .paiScreenBackground()
        .accessibilityIdentifier("computer-call-screen")
        .onDisappear {
            Task { await controller.end() }
        }
        .interactiveDismissDisabled()
    }

    private func statusText(controller: ComputerCallController) -> String {
        switch controller.session.connectionState {
        case .idle:
            return controller.setupFailure == nil ? "Call ended." : "Couldn't connect."
        case .connecting:
            return "Connecting…"
        case .reconnecting:
            return "Reconnecting…"
        case .active:
            if controller.session.busOwner == .call {
                return "Connected to a Kai session."
            }
            return controller.isSpeaking ? "Computer is speaking…" : "Listening…"
        }
    }
}
