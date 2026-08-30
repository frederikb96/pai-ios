import PAIKit
import PhotosUI
import SwiftUI

/// The message composer, mounted under a session's transcript. Exported for the transcript screen
/// to place directly under its scroll view; it needs only a session id and reads everything
/// else from the environment.
///
/// Serves one session's chat. Replaced entirely by ``NonDrivableComposerBar`` when the session is
/// not drivable — a subagent, a session on an offline machine's own grey state, or one PAI simply
/// is not running right now — matching the web's `MessageInput.tsx`, which swaps the whole bar
/// rather than merely disabling a text field.
struct ComposerBar: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(DraftStore.self) private var drafts
    @Environment(TranscriptStore.self) private var transcript
    @Environment(SettingsStore.self) private var settings
    @Environment(MachineStore.self) private var machines
    @Environment(SessionListStore.self) private var sessions

    let sessionID: String

    @State private var draftStore: DraftStore?
    @State private var voiceController: VoiceRecorderController?

    @State private var text = ""
    @State private var textHeight: CGFloat = ComposerTextEditor.minHeight
    @State private var scrollToTailOnNextUpdate = false
    @State private var preVoiceText = ""

    @State private var stagedAttachments: [StagedAttachment] = []
    @State private var isSending = false
    @State private var sendErrorMessage: String?

    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var showingTemporaryNote = false
    @State private var showingRecordingsSheet = false

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    var body: some View {
        Group {
            if let session = currentSession, !SessionListDomain.isDrivable(session) {
                NonDrivableComposerBar(session: session, machines: machines)
            } else if let draftStore, let voiceController {
                drivableComposer(draftStore: draftStore, voiceController: voiceController)
            } else {
                Color.clear.frame(height: ComposerTextEditor.minHeight)
            }
        }
        .task {
            guard draftStore == nil, let connection = environment.connection else { return }
            let newDraftStore = drafts
            let newVoiceController = VoiceRecorderController(
                apiClient: connection.apiClient, settingsStore: connection.settings)
            draftStore = newDraftStore
            voiceController = newVoiceController
            await newDraftStore.syncFromServer()
            text = newDraftStore.draft(for: sessionID).text
        }
        .task(id: sessionID) {
            // Polls this session's draft while the composer is on screen, so a message half-typed
            // on another device shows up here live — the same 10s cadence the web's `App.tsx`
            // polls drafts on, scoped to just the composer's own lifetime rather than the whole
            // app.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                await draftStore?.syncFromServer()
                if let draftStore, draftStore.draft(for: sessionID).text != text, !isSending {
                    text = draftStore.draft(for: sessionID).text
                }
            }
        }
        .onDisappear {
            guard let draftStore else { return }
            Task { await draftStore.flush(key: sessionID) }
        }
    }

    // MARK: - Drivable composer

    @ViewBuilder
    private func drivableComposer(draftStore: DraftStore, voiceController: VoiceRecorderController) -> some View {
        VStack(spacing: 6) {
            if isMachineOffline {
                Text("\(offlineMachineName ?? "This machine") is offline — this is delivered when it comes back.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VoiceRecordingIndicator(controller: voiceController)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let voiceFailureMessage = voiceFailureMessage(controller: voiceController) {
                Text(voiceFailureMessage)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice-failure-message")
            }

            if !stagedAttachments.isEmpty {
                AttachmentPreviewStrip(attachments: stagedAttachments, onRemove: removeAttachment)
            }

            if let sendErrorMessage {
                Text(sendErrorMessage)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ComposerActionMenu(
                    hasSession: true,
                    onPastRecordings: { showingRecordingsSheet = true },
                    onAddPhoto: { showingPhotoPicker = true },
                    onAddFile: { showingFilePicker = true },
                    onTemporaryNote: { showingTemporaryNote = true },
                    onCancel: { Task { await cancelSession() } }
                )

                ComposerTextEditor(
                    text: textBinding(draftStore: draftStore), height: $textHeight, placeholder: "Message PAI...",
                    scrollToTailOnNextUpdate: $scrollToTailOnNextUpdate
                )
                .frame(height: textHeight)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                if voiceController.state == .recording || voiceController.state == .stopping
                    || voiceController.state == .paused || voiceController.state == .reconnecting
                {
                    MuteButton(controller: voiceController) { voiceController.toggleMute() }
                } else {
                    sendButton(draftStore: draftStore)
                }

                VoiceRecorderButton(controller: voiceController) {
                    Task { await toggleRecording(draftStore: draftStore, voiceController: voiceController) }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        // A translucent system material rather than an opaque fill — the composer reads as the
        // edge of the screen scrolling under it, not as a floating panel of a different colour.
        // Matches `CreateSessionView`'s own composer-equivalent bar, which already uses this.
        .background(.bar)
        .sheet(isPresented: $showingPhotoPicker) {
            PhotoAttachmentPicker { staged in stageAttachments(staged) }
        }
        .sheet(isPresented: $showingFilePicker) {
            FileAttachmentPicker { staged in stageAttachments(staged) }
        }
        .sheet(isPresented: $showingTemporaryNote) {
            TemporaryNoteSheet { attachment in stageAttachments([attachment]) }
        }
        .sheet(isPresented: $showingRecordingsSheet) {
            RecordingsSheet(
                controller: voiceController,
                onInsertTranscript: { prefixed in appendTranscript(prefixed, draftStore: draftStore) },
                onAttach: { files in stageAttachments(files) }
            )
        }
        .accessibilityIdentifier("composer-bar")
    }

    private func sendButton(draftStore: DraftStore) -> some View {
        Button {
            send(draftStore: draftStore)
        } label: {
            if isSending {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
            }
        }
        .disabled(!canSend || isSending)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("composer-send-button")
    }

    // MARK: - Text / drafts

    private func textBinding(draftStore: DraftStore) -> Binding<String> {
        Binding(
            get: { text },
            set: { newValue in
                text = newValue
                draftStore.setDraftText(key: sessionID, text: newValue)
            }
        )
    }

    private func appendTranscript(_ prefixedText: String, draftStore: DraftStore) {
        let combined = text.isEmpty ? prefixedText : "\(text) \(prefixedText)"
        text = combined
        draftStore.setDraftText(key: sessionID, text: combined)
    }

    // MARK: - Voice

    /// `setupFailure` (permission denied, `AVAudioSession` could not configure) and
    /// `lastStartFailure` (the mint/connect itself failed — key not configured, ElevenLabs
    /// unreachable, not permitted) were both tracked faithfully with nothing ever reading either
    /// one: tapping the mic did nothing and said nothing, which reads identically to the app being
    /// broken. Both reset to `nil` at the top of the controller's own `start()`, so this clears
    /// itself on the next attempt without anything here needing to do so explicitly.
    private func voiceFailureMessage(controller: VoiceRecorderController) -> String? {
        controller.setupFailure?.userMessage ?? controller.lastStartFailure?.userMessage
    }

    private func toggleRecording(draftStore: DraftStore, voiceController: VoiceRecorderController) async {
        switch voiceController.state {
        case .idle:
            preVoiceText = text
            await voiceController.start()
            observeLiveTranscript(voiceController: voiceController, draftStore: draftStore)
        case .recording, .connecting, .paused, .reconnecting:
            // A tap always means "end the take", regardless of which of these mid-take states it
            // caught — `VoiceRecordingSession.stop` accepts all of them.
            let finalText = await voiceController.stop()
            applyVoiceResult(finalText, draftStore: draftStore)
        case .stopping:
            break
        }
    }

    /// Streams the live partial into the composer as it grows — the `stt-rec: ` prefix is written
    /// once, at the moment recording starts, and only the text after it keeps changing, matching
    /// `VoiceRecordingSession`'s own documented contract for `transcribedText` vs. `result.prefixedText`.
    ///
    /// Keeps polling through `.paused`/`.reconnecting` rather than exiting — a resumed take needs
    /// this same loop still running to pick its live text back up, and nothing else restarts it.
    private func observeLiveTranscript(voiceController: VoiceRecorderController, draftStore: DraftStore) {
        Task {
            var lastPartial = ""
            while voiceController.state != .idle {
                let partial = voiceController.transcribedText
                if partial != lastPartial {
                    lastPartial = partial
                    let live = Self.composeLiveText(pre: preVoiceText, partial: partial)
                    text = live
                    scrollToTailOnNextUpdate = true
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private static func composeLiveText(pre: String, partial: String) -> String {
        guard !partial.isEmpty else { return pre }
        let prefixed = "\(VoiceRecordingResult.sttPrefix)\(partial)"
        return pre.isEmpty ? prefixed : "\(pre) \(prefixed)"
    }

    private func applyVoiceResult(_ prefixedText: String, draftStore: DraftStore) {
        guard !prefixedText.isEmpty else {
            text = preVoiceText
            draftStore.setDraftText(key: sessionID, text: preVoiceText)
            return
        }
        let combined = preVoiceText.isEmpty ? prefixedText : "\(preVoiceText) \(prefixedText)"
        text = combined
        draftStore.setDraftText(key: sessionID, text: combined)
    }

    // MARK: - Send

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty
    }

    private func send(draftStore: DraftStore) {
        guard canSend, !isSending, let connection = environment.connection else { return }

        let messageText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsSnapshot = stagedAttachments
        let files = attachmentsSnapshot.map {
            PaiFileUpload(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }

        if !messageText.isEmpty { settings.saveSentMessage(messageText) }

        text = ""
        stagedAttachments = []
        isSending = true
        sendErrorMessage = nil

        let sendTask = Task<PostMessageResponse, Error> {
            try await connection.apiClient.postMessage(sessionId: sessionID, message: messageText, files: files)
        }
        if !messageText.isEmpty {
            transcript.trackSend(sessionId: sessionID, text: messageText, send: sendTask)
        }

        Task {
            do {
                _ = try await sendTask.value
                draftStore.clearDraft(key: sessionID)
            } catch {
                // The web keeps the text and files on a failed send so nothing typed is lost —
                // the draft itself is never cleared until the request actually resolves.
                text = messageText
                stagedAttachments = attachmentsSnapshot
                sendErrorMessage = (error as? PaiError)?.userMessage ?? "Failed to send message"
            }
            isSending = false
        }
    }

    private func removeAttachment(_ attachment: StagedAttachment) {
        stagedAttachments.removeAll { $0.id == attachment.id }
    }

    /// The one entry point every attachment source (photo picker, file picker, temporary note,
    /// recordings sheet) funnels through — a 50MB file discovered here fails immediately with a
    /// named reason, rather than staging, previewing, and only failing at send with a 413 the web
    /// has no earlier warning for.
    private func stageAttachments(_ staged: [StagedAttachment]) {
        let oversize = staged.filter { $0.currentSize > maxAttachmentBytes }
        let accepted = staged.filter { $0.currentSize <= maxAttachmentBytes }
        stagedAttachments.append(contentsOf: accepted)
        if let first = oversize.first {
            let suffix = oversize.count > 1 ? " and \(oversize.count - 1) other file(s)" : ""
            sendErrorMessage = "\(first.filename)\(suffix) exceeds the 50MB limit and was not attached."
        }
    }

    private func cancelSession() async {
        // Errors are swallowed on purpose, matching the web exactly: tapping Cancel on a session
        // with nothing running, or with the agent disconnected, is a no-op either way.
        _ = try? await environment.connection?.apiClient.cancelSession(sessionId: sessionID)
    }

    // MARK: - Session / machine lookup

    private var currentSession: Session? {
        sessions.rows.first { $0.session.id == sessionID }?.session
    }

    private var isMachineOffline: Bool {
        offlineMachineName != nil
    }

    private var offlineMachineName: String? {
        guard let session = currentSession else { return nil }
        let slug = session.agent ?? MachineStore.defaultMachineSlug
        guard let machine = machines.allMachines.first(where: { $0.slug == slug }), !machine.online else { return nil }
        return machine.displayName
    }
}
