import PAIKit
import SwiftUI

/// Call mode, full-screen — a huge state label and a manual control for every command, since
/// voice commands will misfire and a screen only voice can drive is a trap.
struct CallModeScreen: View {
    let sessionID: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var entryFailed = false

    private var callMode: CallModeController? { environment.connection?.callMode }

    var body: some View {
        ZStack {
            PaiPalette.Semantic.screenBackground.ignoresSafeArea()

            if entryFailed {
                entryFailureView
            } else if let callMode, let store = callMode.store {
                content(callMode: callMode, store: store)
            } else {
                ProgressView("Connecting…")
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
            }
        }
        .task {
            guard let callMode else {
                entryFailed = true
                return
            }
            let entered = await callMode.enter(sessionID: sessionID)
            entryFailed = !entered
        }
        .onChange(of: callMode?.isActive) { _, isActive in
            guard isActive == false else { return }
            dismiss()
        }
        .accessibilityIdentifier("call-mode-screen")
    }

    private var entryFailureView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(PaiPalette.Semantic.errorText)
            Text("Couldn't start the call — the microphone may already be in use.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Close") { dismiss() }
                .accessibilityIdentifier("call-mode-close")
        }
    }

    @ViewBuilder
    private func content(callMode: CallModeController, store: CallModeStore) -> some View {
        VStack(spacing: 24) {
            Spacer()

            Text(stateLabel(store: store, speech: callMode.speech))
                .font(PaiTypography.screenTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .accessibilityIdentifier("call-mode-state")

            if !store.turnRanges.isEmpty {
                Text("Message pending — say \"Kai send\" or tap Send")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }

            if let blocker = store.blocker {
                Text("The agent is waiting: \(blocker.question)")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            if store.lastSendFailure != nil {
                Text("The last message could not be sent.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }

            Spacer()

            controls(callMode: callMode, store: store)
                .padding(.bottom, 32)
        }
        .padding()
    }

    private func stateLabel(store: CallModeStore, speech: SpeechOutputSession?) -> String {
        if case .speaking = speech?.state {
            return "Speaking"
        }
        switch store.phase {
        case .idle: return "Ended"
        case .entering: return "Connecting…"
        case .listening: return "Listening for \"Kai start\""
        case .collecting: return "Recording"
        case .sending: return "Sending…"
        case .pendingSend: return "Message pending transcription…"
        }
    }

    @ViewBuilder
    private func controls(callMode: CallModeController, store: CallModeStore) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                commandButton("Start", systemImage: "mic.fill", kind: .start, callMode: callMode)
                commandButton("Stop", systemImage: "mic.slash.fill", kind: .stop, callMode: callMode)
            }
            HStack(spacing: 16) {
                commandButton("Send", systemImage: "arrow.up.circle.fill", kind: .send, callMode: callMode)
                commandButton("Skip", systemImage: "forward.fill", kind: .skip, callMode: callMode)
            }
            commandButton(
                "End Call", systemImage: "phone.down.fill", kind: .end, callMode: callMode, isDestructive: true)
        }
    }

    private func commandButton(
        _ title: String, systemImage: String, kind: CommandKind, callMode: CallModeController,
        isDestructive: Bool = false
    ) -> some View {
        Button {
            Task { await callMode.handleManual(kind) }
        } label: {
            Label(title, systemImage: systemImage)
                .font(PaiTypography.bodyEmphasized.font)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .tint(isDestructive ? PaiPalette.Semantic.errorText : PaiPalette.primary500)
        .accessibilityIdentifier("call-mode-\(kind.rawValue)")
    }
}
