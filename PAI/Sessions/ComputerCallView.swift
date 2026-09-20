import PAIKit
import SwiftUI

/// The voice screen: one screen with two faces, and the call decides which one shows.
///
/// The Computer face is a conversation with the switchboard. The call face is what a bus looks
/// like once Computer has connected it into a Kai session — the session's name, what the call is
/// doing, the draft filling in as it is dictated, and a control for each of the things that can
/// otherwise only be said out loud. Moving between them is not navigation: it is the backend
/// re-attaching the bus, reported on `state.bus_owner`, so there is nothing here to tap and no
/// intermediate state to render.
///
/// 🚨 **This screen does not own the call.** `ComputerCallController` lives on the connection for
/// the app's lifetime, so backing out to read a session, find a note or scroll the list leaves
/// the microphone exactly where it was — which is the point, and why this is an ordinary pushed
/// destination rather than a cover with its dismissal disabled. `ComputerCallBar` is what says a
/// call is up once this screen is gone; nothing else would, because nothing ends a call on its
/// own any more.
struct ComputerCallView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessions
    @Environment(DraftStore.self) private var drafts

    var body: some View {
        Group {
            if let controller = environment.connection?.computerCall {
                content(controller: controller)
            } else {
                // Unreachable in practice — every door onto this screen exists only once signed
                // in — but a blank screen with a back button is better than an empty one.
                Text("Not signed in.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .paiScreenBackground()
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("computer-call-screen")
    }

    @ViewBuilder
    private func content(controller: ComputerCallController) -> some View {
        let presentation = presentation(controller: controller)
        VStack(spacing: 20) {
            header(presentation: presentation)

            if let failure = controller.setupFailure {
                Text(failure)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            switch presentation.face {
            case .computer:
                Spacer()
            case .call(let sessionId, _):
                DictatedDraftView(text: drafts.draft(for: sessionId).displayText)
                    // The words a call dictates arrive only through the draft — the backend
                    // writes them into the session's own draft region, never over the voice
                    // socket (`docs/VOICE_PROTOCOL.md`, "Composer text sync … is REST + SSE, not
                    // this socket") — so this screen polls for them at the same one-second
                    // cadence a composer does while its own take is running. Anything slower
                    // reads as a microphone that has stopped working.
                    .task(id: sessionId) {
                        await sessions.ensureSessionLoaded(id: sessionId)
                        while !Task.isCancelled {
                            await drafts.syncFromServer()
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                callControls(presentation: presentation, controller: controller)
            }

            endButton(controller: controller)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 32)
    }

    // MARK: - Header

    @ViewBuilder
    private func header(presentation: ComputerCallPresentation) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon(for: presentation.face))
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(PaiPalette.primary500)
                .accessibilityHidden(true)
            Text(title(for: presentation.face))
                .font(PaiTypography.screenTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
            Text(presentation.status)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .accessibilityIdentifier("computer-call-status")
        }
    }

    private func icon(for face: ComputerCallFace) -> String {
        switch face {
        case .computer: "waveform.circle.fill"
        case .call: "bubble.left.and.text.bubble.right.fill"
        }
    }

    private func title(for face: ComputerCallFace) -> String {
        switch face {
        case .computer: "Computer"
        case .call(_, let name): name ?? "A Kai session"
        }
    }

    // MARK: - Call controls

    /// Row 54's list, as buttons. The three that shape the take sit together and keep their
    /// positions; leaving for Computer sits apart from them, and ending the call apart again —
    /// the two irreversible-feeling things are the two that are not under the thumb.
    @ViewBuilder
    private func callControls(presentation: ComputerCallPresentation, controller: ComputerCallController)
        -> some View
    {
        let isRecording = presentation.enabledCommands.contains(.stop)
        VStack(spacing: 16) {
            HStack(spacing: 28) {
                commandButton(
                    .skip, systemImage: "forward.end.fill", label: "Skip the reply",
                    identifier: "computer-call-skip", presentation: presentation, controller: controller
                )
                // Start and Stop are one control because they cannot both apply: a take is open
                // or it is not. Same shape as the composer's own mic button, which is the
                // gesture this is learnt from.
                takeButton(isRecording: isRecording, presentation: presentation, controller: controller)
                commandButton(
                    .send, systemImage: "arrow.up.circle.fill", label: "Send the message",
                    identifier: "computer-call-send", presentation: presentation, controller: controller
                )
            }
            Button {
                Task { await controller.send(command: .listen) }
            } label: {
                Label("Back to Computer", systemImage: "arrow.uturn.backward")
                    .font(PaiTypography.body.font)
            }
            .disabled(!presentation.enabledCommands.contains(.listen))
            .accessibilityIdentifier("computer-call-listen")
        }
    }

    @ViewBuilder
    private func takeButton(
        isRecording: Bool, presentation: ComputerCallPresentation, controller: ComputerCallController
    ) -> some View {
        let command: VoiceCallCommand = isRecording ? .stop : .start
        Button {
            Task { await controller.send(command: command) }
        } label: {
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(isRecording ? PaiPalette.amber500 : PaiPalette.primary500, in: Circle())
                .opacity(presentation.enabledCommands.contains(command) ? 1 : 0.4)
        }
        .disabled(!presentation.enabledCommands.contains(command))
        .accessibilityLabel(isRecording ? "Stop the message" : "Start dictating")
        .accessibilityIdentifier("computer-call-take")
    }

    @ViewBuilder
    private func commandButton(
        _ command: VoiceCallCommand, systemImage: String, label: String, identifier: String,
        presentation: ComputerCallPresentation, controller: ComputerCallController
    ) -> some View {
        let enabled = presentation.enabledCommands.contains(command)
        Button {
            Task { await controller.send(command: command) }
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(enabled ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
                .frame(width: 56, height: 56)
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    /// Ends the call from this side rather than asking the backend to — see `VoiceCallCommand`'s
    /// own note. That is why it is outside `enabledCommands` and stays tappable in every state,
    /// including the one where the socket is down and nothing else is.
    ///
    /// Becomes a way back in once there is no call: reaching this screen after Computer hung up,
    /// or after a failed connect, would otherwise be a dead end with a red button that does
    /// nothing — and the way back in is the same door every other entry point uses.
    @ViewBuilder
    private func endButton(controller: ComputerCallController) -> some View {
        if controller.isLive {
            Button {
                Task {
                    await controller.end()
                    environment.router.pop()
                }
            } label: {
                Image(systemName: "phone.down.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(PaiPalette.red500, in: Circle())
            }
            .accessibilityLabel("End call with Computer")
            .accessibilityIdentifier("computer-call-end")
        } else {
            Button {
                ComputerCallEntry.open(environment)
            } label: {
                Image(systemName: "phone.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(PaiPalette.primary500, in: Circle())
            }
            .accessibilityLabel("Call Computer")
            .accessibilityIdentifier("computer-call-start")
        }
    }

    // MARK: - Derived state

    private func presentation(controller: ComputerCallController) -> ComputerCallPresentation {
        ComputerCallPresentation.make(
            connectionState: controller.session.connectionState,
            busOwner: controller.session.busOwner,
            phase: controller.session.phase,
            sessionId: controller.session.sessionId,
            sessionName: controller.session.sessionId
                .flatMap { sessions.session(withId: $0) }
                .map { SessionListFormat.displayTitle(for: $0) },
            isSpeaking: controller.isSpeaking,
            canReturnToComputer: controller.session.directSessionId == nil
        )
    }
}

/// The session's draft, read-only, as it fills in.
///
/// Read-only on purpose: this is the one surface where Freddy watches words land rather than
/// types them, and an editable field here would race the region the backend is still writing
/// into. Attachments are deliberately absent — his own instruction; this is about seeing the
/// words.
private struct DictatedDraftView: View {
    let text: String

    private static let tailAnchor = "draft-tail"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(text.isEmpty ? "Nothing dictated yet." : text)
                        .font(PaiTypography.body.font)
                        .foregroundStyle(
                            text.isEmpty ? PaiPalette.Semantic.textFaint : PaiPalette.Semantic.textPrimary
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id(Self.tailAnchor)
                }
                .padding(14)
            }
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 16)
            // Follows the tail as dictation arrives. Unconditional rather than latched, because
            // there is no reader scrolling away from it to protect: this field exists to be
            // watched filling in, and it is short-lived — a take, not a transcript.
            .onChange(of: text) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("computer-call-draft")
    }
}
