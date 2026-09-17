import PAIKit
import SwiftUI

/// Call mode, full-screen — independent recording and speaking status, the live transcript, and
/// a manual control for every command, since voice commands will misfire and a screen only voice
/// can drive is a trap.
struct CallModeScreen: View {
    let sessionID: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var entryFailed = false
    @State private var showingSettings = false

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
        .sheet(isPresented: $showingSettings) {
            CallModeSettingsSheet()
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
        VStack(spacing: 16) {
            // Leaves the screen without ending the call — nothing here calls `exit()`, so the
            // pipeline, the reply feed and speech output all keep running exactly as they would
            // with the screen still on top. Reaching the call again is the plus menu's own
            // "Return to Call" entry, which reopens this same screen and reattaches
            // (`CallModeController.enter(sessionID:)` is a no-op once already bound to it).
            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.down")
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
                .accessibilityIdentifier("call-mode-back")
                Spacer()
                Button {
                    showingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
                .accessibilityIdentifier("call-mode-settings")
                Toggle(
                    "Replies interrupt",
                    isOn: Binding(
                        get: { callMode.interruptsAllowed },
                        set: { callMode.setInterruptsAllowed($0) })
                )
                .toggleStyle(.switch)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)

                .accessibilityIdentifier("call-mode-interrupts")
            }

            // Recording and speaking are independent — both rows can be active at once.
            VStack(alignment: .leading, spacing: 8) {
                statusRow(
                    systemImage: "mic.fill", text: recordingLabel(store: store),
                    isActive: isCollecting(store), accessibilityID: "call-mode-state")
                statusRow(
                    systemImage: "speaker.wave.2.fill", text: speakingLabel(speech: callMode.speech),
                    isActive: isSpeaking(callMode.speech), accessibilityID: "call-mode-speech-state")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            transcriptBox

            if !store.turnRanges.isEmpty {
                Text("Message pending — say \"computer send the message\" or tap Send")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }

            if let blocker = store.blocker {
                Text("The agent is waiting: \(blocker.question)")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                    .multilineTextAlignment(.center)
            }

            if store.lastSendFailure != nil {
                Text("The last message may not have gone through — check before sending it again.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }

            controls(callMode: callMode)
                .padding(.bottom, 16)
        }
        .padding()
    }

    /// The session's draft, where the call writes its live transcript — the same text the
    /// composer shows, kept scrolled to its end while it grows.
    private var transcriptBox: some View {
        let text = environment.connection?.drafts.draft(for: sessionID).text ?? ""
        return ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Say something…" : text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(
                        text.isEmpty ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textPrimary
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                Color.clear.frame(height: 1).id(Self.transcriptBottomID)
            }
            .onChange(of: text) { _, _ in
                proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom)
            }
            .onAppear { proxy.scrollTo(Self.transcriptBottomID, anchor: .bottom) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("call-mode-transcript")
    }

    private static let transcriptBottomID = "call-transcript-bottom"

    private func statusRow(systemImage: String, text: String, isActive: Bool, accessibilityID: String)
        -> some View
    {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(isActive ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
                .frame(width: 24)
            Text(text)
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(isActive ? PaiPalette.Semantic.textPrimary : PaiPalette.Semantic.textMuted)
        }
        .accessibilityIdentifier(accessibilityID)
    }

    private func isCollecting(_ store: CallModeStore) -> Bool {
        if case .collecting = store.phase { return true }
        return false
    }

    private func isSpeaking(_ speech: SpeechOutputSession?) -> Bool {
        if case .speaking = speech?.state { return true }
        return false
    }

    private func recordingLabel(store: CallModeStore) -> String {
        switch store.phase {
        case .idle: return "Ended"
        case .entering: return "Connecting…"
        case .listening: return "Listening for \"computer\""
        case .collecting: return "Recording"
        case .sending: return "Sending…"
        case .pendingSend: return "Message pending transcription…"
        }
    }

    private func speakingLabel(speech: SpeechOutputSession?) -> String {
        guard let speech else { return "Replies off" }
        if case .speaking = speech.state { return "Speaking" }
        let waiting = speech.waitingReplyCount
        if speech.isHeld, waiting > 0 { return waiting == 1 ? "1 reply waiting" : "\(waiting) replies waiting" }
        if waiting > 0 { return "Preparing reply…" }
        return "Quiet"
    }

    @ViewBuilder
    private func controls(callMode: CallModeController) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                commandButton("Start", systemImage: "mic.fill", kind: .start, callMode: callMode)
                commandButton("Stop", systemImage: "mic.slash.fill", kind: .stop, callMode: callMode)
                commandButton("Send", systemImage: "arrow.up.circle.fill", kind: .send, callMode: callMode)
            }
            HStack(spacing: 12) {
                commandButton("Skip", systemImage: "forward.fill", kind: .skip, callMode: callMode)
                commandButton(
                    "End", systemImage: "phone.down.fill", kind: .end, callMode: callMode, isDestructive: true)
            }
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
                .padding(.vertical, 10)
        }
        .buttonStyle(.borderedProminent)
        .tint(isDestructive ? PaiPalette.Semantic.errorText : PaiPalette.primary500)
        .accessibilityIdentifier("call-mode-\(kind.rawValue)")
    }
}
