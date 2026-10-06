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
    @Environment(OutboxStore.self) private var outbox
    @Environment(ToastCenter.self) private var toasts

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
    @State private var showingSentMessagesSheet = false

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Held per session in a store that outlives this view — a file picked, then a trip to another
    /// session and back, must still be attached on return.
    private var stagedAttachments: [StagedAttachment] {
        staging.attachments(for: sessionID)
    }

    /// What the strip actually shows. The join itself lives in the store, beside the upload that
    /// produces the id it joins on.
    private var displayAttachments: [ComposerAttachment] {
        staging.composerAttachments(for: sessionID, draft: drafts.draft(for: sessionID))
    }

    var body: some View {
        Group {
            if let session = currentSession, SessionMoved.isMoved(session) || !SessionListDomain.isDrivable(session) {
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
            // on another device shows up here — the same 10s cadence the web's `App.tsx` polls
            // drafts on, scoped to just the composer's own lifetime rather than the whole app. No
            // longer tightened while dictating here: a live take's own words now arrive through
            // `VoiceRecorderController` writing straight into `DraftStore` as they are transcribed,
            // not through this poll — see `docs/VOICE_PROTOCOL.md`'s `transcript` frame.
            //
            // Nothing is copied out of the store afterwards: the field reads straight through
            // `textBinding`, so `syncFromServer`'s own reconciliation rules (an unflushed local
            // edit beats anything the server can report) are the only thing deciding what wins.
            // A second copy here is what once let this poll overwrite a live voice transcript.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
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
            // A session created by one of the launcher's call tiles: the first turn was just
            // spoken and sent, and the point of the tile was never touching the phone again — so
            // the call opens here, straight inside this session, from the screen the send landed
            // on rather than from the sheet that was dismissing when the session came into being
            // (the same ordering reason `CallModeLaunchRequest.openCall(forSession:)`'s own doc
            // comment gives). A call rather than plain dictation, because a call is what the tile
            // said: the wake word, spoken replies, and no screen to hold.
            if CallModeLaunchRequest.shared.consumeOpenCall(forSession: sessionID) {
                ComputerCallEntry.open(environment, connectSession: sessionID)
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
                // No live transcript can arrive while the connection is anything but
                // `.recording`, or while the silence gate is holding the microphone back — the
                // overlay is what proves the microphone is still capturing in the meantime, which
                // the plain state label alone could not.
                if voiceController.state != .recording || voiceController.isWithholding {
                    VoiceVolumeOverlay(controller: voiceController)
                }
            }

            if let voiceFailureMessage = voiceFailureMessage(controller: voiceController) {
                Text(voiceFailureMessage)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice-failure-message")
            }

            if !displayAttachments.isEmpty {
                AttachmentPreviewStrip(
                    attachments: displayAttachments, onRemove: removeAttachment, onRetry: retryAttachment)
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
                    text: textBinding(draftStore: draftStore, voiceController: voiceController), height: $textHeight,
                    placeholder: "Message PAI...",
                    scrollToTailOnNextUpdate: $scrollToTailOnNextUpdate,
                    onPasteImages: { images in stagePastedImages(images) }
                )
                .frame(height: textHeight)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18))

                ComposerActionMenu(
                    hasSession: true,
                    canGrantSecretAccess: currentSecretGrantable ?? false,
                    canRestorePreviousText: canRestorePreviousText(draftStore: draftStore),
                    offersComputer: true,
                    isOnTheCall: callIsInThisSession,
                    isCallLive: environment.connection?.computerCall.isLive ?? false,
                    onComputer: { ComputerCallEntry.open(environment) },
                    onCallThisSession: {
                        ComputerCallEntry.open(environment, connectSession: sessionID)
                    },
                    offersAttachments: currentSession?.kind != .ultrafast,
                    onPastRecordings: { showingRecordingsSheet = true },
                    onPastMessages: { showingSentMessagesSheet = true },
                    onAddPhoto: { showingPhotoPicker = true },
                    onAddFile: { showingFilePicker = true },
                    onTemporaryNote: { showingTemporaryNote = true },
                    onSecretGrant: { secretGrantTarget = SecretGrantTarget(promptAt: currentSecretPrompt?.at) },
                    onRestorePreviousText: { draftStore.restorePreviousText(key: sessionID) },
                    onCancel: { Task { await cancelSession() } },
                    onUndoSend: { Task { await undoSend() } },
                    onSendNow: { Task { await sendNow() } },
                    onMoveToBackground: { Task { await moveToBackground() } },
                    offersProcessActions: currentSession?.kind != .ultrafast
                )

                VoiceRecorderButton(
                    controller: voiceController,
                    isMine: voiceController.state == .idle || isRecordingHere(voiceController),
                    canStartOverride: micButtonCanStartOverride(voiceController)
                ) {
                    Task { await toggleRecording(draftStore: draftStore, voiceController: voiceController) }
                }

                // Mute holds the slot while a take is actively recording; Finishing gives it back
                // to Send, since that is exactly when pressing it means something (abandon and
                // send what has arrived so far) — the stop-recording design's own rule.
                if isRecordingHere(voiceController), voiceController.state != .stopping {
                    MuteButton(controller: voiceController) { voiceController.toggleMute() }
                } else {
                    sendButton(draftStore: draftStore, voiceController: voiceController)
                }
            }
        }
        // Keeps the field scrolled to the tail while a take's own live text grows. `.task(id:)`
        // cancels on disappear, where a free-standing `Task` would leave one more loop running
        // per visit.
        .task(id: isRecordingHere(voiceController)) {
            guard isRecordingHere(voiceController) else { return }
            var lastText = drafts.draft(for: sessionID).text
            while !Task.isCancelled, isRecordingHere(voiceController) {
                let text = drafts.draft(for: sessionID).text
                if text != lastText {
                    lastText = text
                    scrollToTailOnNextUpdate = true
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        // Leaving mid-drain must not leave the wait running unattended behind a screen nobody is
        // looking at — the same escape a tap or typing gives Freddy while he is still looking.
        .onDisappear {
            guard isRecordingHere(voiceController), voiceController.state == .stopping else { return }
            Task { await voiceController.abandonCurrentTake() }
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
                onAttachVoiceLog: { log in stageAttachments([log]) }
            )
        }
        .sheet(isPresented: $showingSentMessagesSheet) {
            SentMessagesSheet(settings: settings)
        }
        .accessibilityIdentifier("composer-bar")
    }

    private func sendButton(draftStore: DraftStore, voiceController: VoiceRecorderController) -> some View {
        Button {
            send(draftStore: draftStore, voiceController: voiceController)
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
    private func textBinding(draftStore: DraftStore, voiceController: VoiceRecorderController) -> Binding<String> {
        Binding(
            get: { draftStore.draft(for: sessionID).text },
            set: { newValue in
                draftStore.setDraftText(key: sessionID, text: newValue)
                // Only `ComposerTextEditor` reaches this setter — the live take writes its own
                // words straight through `DraftStore` without going through this binding at all —
                // so landing here IS Freddy typing, unambiguously. Typed straight into a Finishing
                // composer means the same thing tapping the button now does: stop waiting on it,
                // since the next arriving segment would otherwise heal right back over what he
                // just typed.
                if isRecordingHere(voiceController), voiceController.state == .stopping {
                    Task { await voiceController.abandonCurrentTake() }
                }
            }
        )
    }

    private var text: String {
        draftStore?.draft(for: sessionID).text ?? ""
    }

    /// Only when the server is holding a different earlier text than what's on screen — two
    /// devices never type at once, so the last writer wins, and this is how the loser gets its
    /// words back. Mirrors the web's own gate in `MessageInput.tsx`.
    private func canRestorePreviousText(draftStore: DraftStore) -> Bool {
        let entry = draftStore.draft(for: sessionID)
        guard let previous = entry.previousText, !previous.isEmpty else { return false }
        return previous != entry.text
    }

    private func appendTranscript(_ prefixedText: String, draftStore: DraftStore) {
        let current = draftStore.draft(for: sessionID).text
        draftStore.setDraftText(
            key: sessionID, text: current.isEmpty ? prefixedText : "\(current) \(prefixedText)")
    }

    /// Whether the live call is inside this session — the third of the three ways back to the
    /// voice screen, and the one that has to be visible from where Freddy already is. Read off
    /// the call's own reported session id rather than anything this screen records, since the
    /// backend is what decides which session a bus is in.
    private var callIsInThisSession: Bool {
        guard let call = environment.connection?.computerCall, call.isLive else { return false }
        return call.session.busOwner == .call && call.session.sessionId == sessionID
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
            // A tap during Finishing means "stop waiting" rather than "start a second stop" —
            // `stop()`'s own wait is already running by the time the button reads `.stopping`, and
            // `abandonCurrentTake()` is what tells that wait to give up immediately instead of
            // sitting out `take_done` or the deadline. Every other mid-take state ends through the
            // ordinary `stop()`, which `VoiceUplinkSession.stop` accepts from all of them — the
            // text itself is already in the draft by then either way.
            if voiceController.state == .stopping {
                await voiceController.abandonCurrentTake()
                return
            }
            await voiceController.stop()
            return
        }

        sendErrorMessage = nil
        switch microphoneHandoverAction(voiceController) {
        case .stopMicrophoneTake:
            // The other session's own take ends exactly as an ordinary tap-to-stop in that
            // composer would — its text is already there, written as the stop itself closes it.
            await voiceController.stop()
        case .startOnly, .alreadyHere:
            break
        }
        await voiceController.start(draftKey: sessionID, preText: draftStore.draft(for: sessionID).text)
    }

    // MARK: - Send

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty
            || !drafts.draft(for: sessionID).attachments.isEmpty
    }

    private func send(draftStore: DraftStore, voiceController: VoiceRecorderController) {
        guard canSend, !isSending, environment.connection != nil else { return }
        isSending = true
        sendErrorMessage = nil
        let isRecordingHereNow = isRecordingHere(voiceController)
        // Finishing (the drain between pressing stop and the take actually completing) is the
        // ordinary way Send is reachable while a take still exists — the send button's own slot
        // shows Mute for every other non-idle state, so this is what the button press actually
        // hits. The wire contract's own rule: seal it, tell the server to abandon rather than
        // wait, and send whatever the box already shows. The `else` below is a defensive fallback
        // for any OTHER caller of this function while genuinely still `.recording` — none exists
        // today — which takes the graceful path instead: stop and let the take's own tail land
        // before reading the text.
        let isFinishing = isRecordingHereNow && voiceController.state == .stopping

        Task {
            if isFinishing {
                await voiceController.abandonCurrentTake()
            } else if isRecordingHereNow {
                await voiceController.stop()
                await draftStore.syncFromServer()
            }

            let messageText = draftStore.draft(for: sessionID).text.trimmingCharacters(in: .whitespacesAndNewlines)
            let attachmentsSnapshot = stagedAttachments
            let uploadedAttachmentIds = draftStore.draft(for: sessionID).attachments.map(\.id)
            // An attachment already uploaded onto this draft is claimed explicitly by id — never
            // "whatever the draft happens to hold" — so a photo staged for the *next* message
            // while this one is still queued is never swept into it. Only what never made it to
            // the server (still uploading, or the upload failed) travels inline, as a fallback.
            let inlineAttachments = attachmentsSnapshot.filter { attachment in
                if case .uploaded = attachment.uploadState { return false }
                return true
            }
            if !messageText.isEmpty { settings.saveSentMessage(messageText) }

            let inlineFiles = inlineAttachments.map { attachment in
                OutboxInlineFile(
                    localId: attachment.id.uuidString, filename: attachment.filename, mimeType: attachment.mimeType)
            }
            let inlineFileData = Dictionary(
                uniqueKeysWithValues: zip(inlineFiles.map(\.localId), inlineAttachments.map(\.data)))
            let entry = OutboxEntry(
                target: .session(sessionId: sessionID), text: messageText, draftAttachmentIds: uploadedAttachmentIds,
                inlineFiles: inlineFiles)

            // Cleared before the request even leaves — the whole point of the outbox is that the
            // bubble it drives (`OutboxBubbleStack`) exists, and survives a kill, before any
            // network call has started. Nothing here waits on the network: the queue delivers it,
            // exactly once, whenever the link allows, and its own state is what Freddy sees from
            // here on — queued, sending, or failed with Retry/Put back in composer/Discard.
            draftStore.setDraftText(key: sessionID, text: "")
            staging.set([], for: sessionID)
            // The draft version this send consumes is recorded by the outbox's own handover, the
            // one place that learns a send has landed — nothing here may wait for that, since the
            // same handover retires the entry at the moment it is sent.
            outbox.enqueue(entry, inlineFileData: inlineFileData)
            isSending = false
        }
    }

    private func removeAttachment(_ attachment: ComposerAttachment) {
        staging.remove(attachment, from: sessionID, via: drafts)
    }

    private func retryAttachment(_ attachment: ComposerAttachment) {
        guard case .staged(let staged) = attachment else { return }
        staging.retryUpload(id: staged.id, in: sessionID, via: drafts)
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
        if let refused = staging.stage(staged, for: sessionID, via: drafts) {
            sendErrorMessage = refused
        }
    }

    private func cancelSession() async {
        // Errors are swallowed on purpose, matching the web exactly: tapping Cancel on a session
        // with nothing running, or with the agent disconnected, is a no-op either way.
        _ = try? await environment.connection?.apiClient.cancelSession(sessionId: sessionID)
    }

    /// The same action the per-bubble "Pull back into composer" runs: names what may already be on
    /// the server by id, and puts a message back in the composer only when the server says it was
    /// withdrawn. An explicit tap gets an answer even when there was nothing to undo.
    private func undoSend() async {
        let summary = await outbox.undoSend(sessionId: sessionID, drafts: drafts)
        if let text = summary.toast(announceNothing: true) { toasts.show(text) }
    }

    private func sendNow() async {
        guard let apiClient = environment.connection?.apiClient else { return }
        if let result = try? await apiClient.sendNow(sessionId: sessionID) {
            toasts.show(result.toastText)
        } else {
            toasts.show("Could not send now", kind: .error)
        }
    }

    private func moveToBackground() async {
        guard let apiClient = environment.connection?.apiClient else { return }
        if let result = try? await apiClient.moveToBackground(sessionId: sessionID) {
            toasts.show(result.toastText)
        } else {
            toasts.show("Could not move to the background", kind: .error)
        }
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
        // A pod-resident kind is answered by the pod, whatever its machine is doing.
        if let kind = session.kind, sessionKindsPodResident.contains(kind) { return nil }
        let slug = session.agent ?? MachineStore.defaultMachineSlug
        guard let machine = machines.allMachines.first(where: { $0.slug == slug }), !machine.online else { return nil }
        return machine.displayName
    }
}
