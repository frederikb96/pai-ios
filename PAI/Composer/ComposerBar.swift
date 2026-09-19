import PAIKit
import PhotosUI
import SwiftUI

/// Identifies which grant sheet `ComposerBar` has on screen — a session's own `SecretPrompt.at`
/// when one is driving it, or `nil` for the plus menu's ordinary manual open with nothing
/// outstanding. `.sheet(item:)`'s item rather than a plain `Bool`, so a *different* prompt (a
/// changed `at`) arriving while the sheet is already open gets a fresh identity and the sheet's
/// own `.task` re-fetches, instead of silently continuing to show whatever it first loaded.
private struct SecretGrantTarget: Identifiable {
    let promptAt: String?
    var id: String { promptAt ?? "manual" }
}

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
    @Environment(StagedAttachmentStore.self) private var staging

    let sessionID: String

    @State private var draftStore: DraftStore?

    @State private var textHeight: CGFloat = ComposerTextEditor.minHeight
    @State private var scrollToTailOnNextUpdate = false

    @State private var isSending = false
    @State private var sendErrorMessage: String?

    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var showingTemporaryNote = false
    @State private var secretGrantTarget: SecretGrantTarget?
    /// The `SecretPrompt.at` this screen has already shown and closed — set on every dismissal of
    /// `secretGrantTarget`'s sheet, whatever ended it (Decline, Grant, Cancel, or a swipe down), so
    /// the same still-outstanding prompt does not pop back up on the next unrelated re-render, and
    /// only a genuinely new prompt (a different `at`) does. Lives no longer than this view: leaving
    /// the session and coming back is a fresh `ComposerBar` with this reset to `nil`, which is what
    /// makes re-entering the session present an unanswered prompt again.
    @State private var dismissedSecretPromptAt: String?
    @State private var showingRecordingsSheet = false

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Held per session in a store that outlives this view — a file picked, then a trip to another
    /// session and back, must still be attached on return.
    private var stagedAttachments: [StagedAttachment] {
        staging.attachments(for: sessionID)
    }

    var body: some View {
        Group {
            if let session = currentSession, !SessionListDomain.isDrivable(session) {
                NonDrivableComposerBar(session: session, machines: machines)
            } else if let draftStore, let voiceController = environment.connection?.voice {
                drivableComposer(draftStore: draftStore, voiceController: voiceController)
            } else {
                Color.clear.frame(height: ComposerTextEditor.minHeight)
            }
        }
        .task {
            guard draftStore == nil, environment.connection != nil else { return }
            draftStore = drafts
            await drafts.syncFromServer()
        }
        .task(id: sessionID) {
            // Polls this session's draft while the composer is on screen, so a message half-typed
            // on another device shows up here live — the same 10s cadence the web's `App.tsx`
            // polls drafts on, scoped to just the composer's own lifetime rather than the whole
            // app. Tightened to 1s while THIS composer's own take is dictating: the words a live
            // take produces arrive only through this poll now (the backend writes them straight
            // into the draft's own region — no local transcript feed exists to show them sooner —
            // see `docs/VOICE_PROTOCOL.md`'s "Composer text sync ... is REST + SSE, not this
            // socket"), so 10s would read as a broken microphone for most of every sentence.
            //
            // Nothing is copied out of the store afterwards: the field reads straight through
            // `textBinding`, so `syncFromServer`'s own reconciliation rules (an unflushed local
            // edit beats anything the server can report) are the only thing deciding what wins.
            // A second copy here is what once let this poll overwrite a live voice transcript.
            while !Task.isCancelled {
                let interval: Duration =
                    environment.connection?.voice.activeDraftKey == sessionID ? .seconds(1) : .seconds(10)
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await draftStore?.syncFromServer()
            }
        }
        .onDisappear {
            guard let draftStore else { return }
            Task { await draftStore.flush(key: sessionID) }
        }
        .onAppear {
            presentSecretPromptIfNeeded()
            // A session created by one of the launcher's call tiles, or by the new-session
            // screen's own "Dictate Hands-Free": the first turn was just spoken and sent, and the
            // point of the tile was never touching the phone again — so dictation resumes here,
            // into this session's own draft, from the screen the send landed on rather than from
            // the sheet that was dismissing when the session came into being (the same ordering
            // reason `CallModeLaunchRequest.openCall(forSession:)`'s own doc comment gives).
            if CallModeLaunchRequest.shared.consumeOpenCall(forSession: sessionID),
                let voiceController = environment.connection?.voice
            {
                Task { await voiceController.start(draftKey: sessionID, preText: "") }
            }
        }
        .onChange(of: currentSecretPrompt) { _, _ in presentSecretPromptIfNeeded() }
        .sheet(item: $secretGrantTarget, onDismiss: { dismissedSecretPromptAt = currentSecretPrompt?.at }) { _ in
            SecretGrantSheet(sessionID: sessionID, session: currentSession, prompt: currentSecretPrompt)
        }
    }

    /// Pops the same sheet the plus menu opens, unprompted, whenever this session is carrying a
    /// gated-secret prompt this screen hasn't already been dismissed for — `SecretPrompt.at`
    /// identifies which one, so a prompt already closed does not reopen on the next unrelated
    /// re-render (a poll, a keystroke), and a genuinely new prompt (a different `at`) does.
    private func presentSecretPromptIfNeeded() {
        guard let currentSecretPrompt, currentSecretPrompt.at != dismissedSecretPromptAt else { return }
        secretGrantTarget = SecretGrantTarget(promptAt: currentSecretPrompt.at)
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

            // Only for this session's own take — the recorder is shared, and a level meter
            // running above a composer that is not recording is a claim about the wrong screen.
            if isRecordingHere(voiceController) {
                VoiceRecordingIndicator(controller: voiceController)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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

            // Text field, then plus, then mic, then send — the controls run left to right in
            // the order a message is built, and the two that end a message sit under the thumb
            // at the right edge.
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextEditor(
                    text: textBinding(draftStore: draftStore), height: $textHeight, placeholder: "Message PAI...",
                    scrollToTailOnNextUpdate: $scrollToTailOnNextUpdate,
                    onPasteImages: { images in stagePastedImages(images) }
                )
                .frame(height: textHeight)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                ComposerActionMenu(
                    hasSession: true,
                    canGrantSecretAccess: currentSecretGrantable ?? false,
                    onPastRecordings: { showingRecordingsSheet = true },
                    onAddPhoto: { showingPhotoPicker = true },
                    onAddFile: { showingFilePicker = true },
                    onTemporaryNote: { showingTemporaryNote = true },
                    onSecretGrant: { secretGrantTarget = SecretGrantTarget(promptAt: currentSecretPrompt?.at) },
                    onCancel: { Task { await cancelSession() } }
                )

                VoiceRecorderButton(
                    controller: voiceController,
                    isMine: voiceController.state == .idle || isRecordingHere(voiceController),
                    canStartOverride: micButtonCanStartOverride(voiceController)
                ) {
                    Task { await toggleRecording(draftStore: draftStore, voiceController: voiceController) }
                }

                if isRecordingHere(voiceController) {
                    MuteButton(controller: voiceController) { voiceController.toggleMute() }
                } else {
                    sendButton(draftStore: draftStore)
                }
            }
        }
        // Keeps the field scrolled to the tail while a take's own draft region grows — the 1s
        // draft poll above is what actually pulls the new words in; this only notices once they
        // arrive. `.task(id:)` cancels on disappear, where a free-standing `Task` would leave one
        // more loop running per visit.
        .task(id: isRecordingHere(voiceController)) {
            guard isRecordingHere(voiceController) else { return }
            var lastText = drafts.draft(for: sessionID).displayText
            while !Task.isCancelled, isRecordingHere(voiceController) {
                let text = drafts.draft(for: sessionID).displayText
                if text != lastText {
                    lastText = text
                    scrollToTailOnNextUpdate = true
                }
                try? await Task.sleep(for: .milliseconds(150))
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

    /// 🚨 **The draft store is the field's only storage — there is deliberately no second copy
    /// in this view.** A mirrored `@State` string has to be reconciled with the store on every
    /// path that can write either one (typing, the ten-second sync, a voice transcript arriving,
    /// a failed send restoring what was typed), and the one that got missed was the voice
    /// transcript: it wrote the mirror, the sync overwrote the mirror from the store, and
    /// everything transcribed since the last pause vanished until the next word rewrote it.
    private func textBinding(draftStore: DraftStore) -> Binding<String> {
        Binding(
            get: { draftStore.draft(for: sessionID).displayText },
            set: { newValue in draftStore.setDraftText(key: sessionID, text: newValue) }
        )
    }

    private var text: String {
        draftStore?.draft(for: sessionID).displayText ?? ""
    }

    private func appendTranscript(_ prefixedText: String, draftStore: DraftStore) {
        let current = draftStore.draft(for: sessionID).displayText
        draftStore.setDraftText(
            key: sessionID, text: current.isEmpty ? prefixedText : "\(current) \(prefixedText)")
    }

    /// Whether the running take is *this* composer's. The recorder is app-wide, so a take started
    /// on another session — or in the new-session sheet — must not turn this bar into a recording
    /// bar for a recording that is not its own.
    private func isRecordingHere(_ controller: VoiceRecorderController) -> Bool {
        controller.activeDraftKey == sessionID && controller.state != .idle
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

    /// What tapping the mic in this session's composer does to whatever else is claiming the one
    /// shared microphone — Freddy's "the new one wins, the old one stops cleanly" rule
    /// (`VoiceHandover.forMicrophoneTap`), never applicable while this session already owns the
    /// running take (`isRecordingHere` handles that tap as an ordinary stop instead).
    private func microphoneHandoverAction(_ controller: VoiceRecorderController) -> VoiceHandoverAction {
        let running = controller.state == .idle ? nil : controller.activeDraftKey
        return VoiceHandover.forMicrophoneTap(sessionID: sessionID, microphoneTakeSessionID: running)
    }

    /// `nil` defers to `VoiceRecorderButton`'s own ordinary gate (`controller.canStart`) — the
    /// case where a tap genuinely cannot start anything (already starting, not signed in).
    /// `true` forces the button tappable even though `controller.canStart` would refuse it: a
    /// handover tap does not itself start anything until the thing it is taking over has stopped,
    /// so the ordinary "is the microphone free right now" gate does not apply to it.
    private func micButtonCanStartOverride(_ controller: VoiceRecorderController) -> Bool? {
        guard !isRecordingHere(controller) else { return nil }
        switch microphoneHandoverAction(controller) {
        case .startOnly, .alreadyHere: return nil
        case .stopMicrophoneTake: return true
        }
    }

    private func toggleRecording(draftStore: DraftStore, voiceController: VoiceRecorderController) async {
        if isRecordingHere(voiceController) {
            // A tap always means "end the take", regardless of which mid-take state it caught —
            // `VoiceUplinkSession.stop` accepts all of them. The text itself is already in the
            // draft's own region by now, on every one of the ways a take can end; nothing is
            // applied here.
            guard voiceController.state != .stopping else { return }
            await voiceController.stop()
            return
        }

        sendErrorMessage = nil
        switch microphoneHandoverAction(voiceController) {
        case .stopMicrophoneTake:
            // The other session's own take ends exactly as an ordinary tap-to-stop in that
            // composer would — its region is already there, closed by the stop itself.
            await voiceController.stop()
        case .startOnly, .alreadyHere:
            break
        }
        await voiceController.start(draftKey: sessionID, preText: draftStore.draft(for: sessionID).text)
    }

    // MARK: - Send

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty
    }

    private func send(draftStore: DraftStore) {
        guard canSend, !isSending, let connection = environment.connection else { return }
        isSending = true
        sendErrorMessage = nil
        let wasRecording = isRecordingHere(connection.voice)

        Task {
            // A still-running take is still writing into this draft's own region on the backend —
            // sending while it is open would race that write and post a message shorter than
            // what was actually said. Stopping first closes the region cleanly; one more sync
            // catches whatever committed in the instant before the stop reached the backend, so
            // the words spoken right up to "computer send the message" are never the ones left
            // behind.
            if wasRecording {
                await connection.voice.stop()
                await draftStore.syncFromServer()
            }

            let messageText = draftStore.draft(for: sessionID).displayText.trimmingCharacters(
                in: .whitespacesAndNewlines)
            let attachmentsSnapshot = stagedAttachments
            let files = attachmentsSnapshot.map {
                PaiFileUpload(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            }
            if !messageText.isEmpty { settings.saveSentMessage(messageText) }

            draftStore.setDraftText(key: sessionID, text: "")
            staging.set([], for: sessionID)

            let sendTask = Task<PostMessageResponse, Error> {
                try await connection.apiClient.postMessage(sessionId: sessionID, message: messageText, files: files)
            }
            if !messageText.isEmpty {
                transcript.trackSend(sessionId: sessionID, text: messageText, send: sendTask)
            }

            do {
                _ = try await sendTask.value
                draftStore.clearDraft(key: sessionID)
            } catch {
                // The web keeps the text and files on a failed send so nothing typed is lost —
                // the draft itself is never cleared until the request actually resolves.
                draftStore.setDraftText(key: sessionID, text: messageText)
                staging.set(attachmentsSnapshot, for: sessionID)
                sendErrorMessage = (error as? PaiError)?.userMessage ?? "Failed to send message"
            }
            isSending = false
        }
    }

    private func removeAttachment(_ attachment: StagedAttachment) {
        staging.remove(id: attachment.id, from: sessionID)
    }

    /// The one entry point every attachment source (photo picker, file picker, temporary note,
    /// recordings sheet) funnels through — a 50MB file discovered here fails immediately with a
    /// named reason, rather than staging, previewing, and only failing at send with a 413 the web
    /// has no earlier warning for.
    /// Pasted images go through the same door as the photo picker's — the same compression, the
    /// same size limit, the same preview strip. Nothing about a paste makes it a different kind
    /// of attachment.
    private func stagePastedImages(_ images: [PastedImage]) {
        stageAttachments(
            images.map { AttachmentCompression.stage(data: $0.data, filename: $0.filename, mimeType: $0.mimeType) })
    }

    private func stageAttachments(_ staged: [StagedAttachment]) {
        let oversize = staged.filter { $0.currentSize > maxAttachmentBytes }
        let accepted = staged.filter { $0.currentSize <= maxAttachmentBytes }
        staging.append(accepted, to: sessionID)
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

    /// The transcript's own live SSE figure wins once it has reported anything for this session —
    /// same precedence `SessionDetailView.currentActivityCounts` uses — so the grant entry follows
    /// a session going live or closing without waiting for `sessions`' own row to catch up.
    private var currentSecretGrantable: Bool? {
        transcript.liveStatus[sessionID]?.secretGrantable ?? currentSession?.secretGrantable
    }

    /// Same precedence as `currentSecretGrantable` — the live SSE figure wins once it has reported
    /// anything for this session.
    private var currentSecretPrompt: SecretPrompt? {
        transcript.liveStatus[sessionID]?.secretPrompt ?? currentSession?.secretPrompt
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
