import PAIKit
import PhotosUI
import SwiftUI

/// The "New Session" flow, presented as a sheet from the session list.
///
/// A welcoming compose screen, not a settings form — the vocabulary of `Section`/section headers
/// belongs to a screen that configures something that already exists; this one starts a
/// conversation, and reads that way: a title and an invitation, the launch choices as pills
/// anyone can scan at a glance, and a real composer at the bottom with the same photo/file/voice
/// affordances the session composer has. See the `30.9`/`40.6` design rows for the reasoning.
///
/// A sheet rather than a pushed screen: this is a self-contained compose action with no reason
/// to leave a trail on the navigation stack, the same choice iOS makes for Mail's and Messages'
/// own "new" flows.
///
/// `CreateSessionStore` is built fresh for each presentation rather than held in the shared
/// environment — the store's own doc comment is explicit that the machine choice must never be
/// remembered between visits, and a store scoped to this view's lifetime is what makes that true
/// for free rather than needing an explicit reset call every time the sheet reopens.
struct CreateSessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessionList
    @Environment(MachineStore.self) private var machines
    @Environment(SettingsStore.self) private var settings
    @Environment(DraftStore.self) private var drafts
    @Environment(StagedAttachmentStore.self) private var staging
    @Environment(ClaudeAuthStore.self) private var claudeAuth

    @State private var createSession: CreateSessionStore?
    @State private var isPresentingDirectoryBrowser = false
    @State private var errorMessage: String?

    // MARK: - Composer state
    //
    // Text and attachments both live in the shared `DraftStore`/`StagedAttachmentStore`, under
    // `DraftKey.newSession` — the same mechanism a session's own composer uses, so cancelling out
    // of this screen and coming back (or a force-quit) loses nothing typed or attached. Only the
    // machine and launch-type pickers stay local view state; `CreateSessionStore`'s doc comment
    // explains why.

    @State private var textHeight: CGFloat = ComposerTextEditor.minHeight
    @State private var scrollToTailOnNextUpdate = false
    @State private var preVoiceText = ""
    @FocusState private var isComposerFocused: Bool

    @State private var showingPhotoPicker = false
    @State private var showingFilePicker = false
    @State private var showingTemporaryNote = false
    @State private var showingRecordingsSheet = false

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .onDisappear {
            // 🚨 The recorder is app-wide now, so it survives this sheet — and nothing else can
            // reach a take started here, because this is the only screen that recognises a take
            // with no draft key as its own. Left running it would hold the one microphone
            // indefinitely, disabling the record button in every session's composer with no
            // visible cause. The audio itself is still saved, so it is recoverable from Past
            // Recordings; only the live transcript, which had nowhere durable to go from this
            // screen, is lost.
            if let voiceController = environment.connection?.voice, isRecordingHere(voiceController) {
                Task { await voiceController.stop() }
            }
            // Debounced writes land regardless (the pending `Task` lives on `DraftStore`, not on
            // this view), but flushing explicitly here is what makes Cancel-then-force-quit safe
            // without depending on the 700ms window having already elapsed.
            Task { await drafts.flush(key: DraftKey.newSession) }
        }
        .task {
            guard createSession == nil, let connection = environment.connection else { return }
            let store = CreateSessionStore(machines: machines, api: connection.apiClient)
            createSession = store
            // Freshest possible online/offline picture at the moment stakes are highest: a
            // session about to launch on whichever machine turns out to be reachable.
            await machines.refresh()
            await store.start()
            await drafts.syncFromServer()
            // A persisted launch choice — restored after a relaunch, or set by a home-screen
            // shortcut ahead of navigating here — wins over the preselection `store.start()` just
            // applied. `workingDir` implies `sessionType == "custom"` already (`selectWorkingDir`
            // sets both), so restoring it alone is enough; a plain type restores through its own
            // setter.
            let persisted = drafts.draft(for: DraftKey.newSession)
            if let workingDir = persisted.workingDir {
                store.selectWorkingDir(workingDir)
            } else if let sessionType = persisted.sessionType {
                store.selectSessionType(sessionType)
            }
            store.selectModel(persisted.model)
            // The point of this screen is the text field — true whether it was reached by tapping
            // "+" or by a home-screen shortcut built to land here ready to type.
            isComposerFocused = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if let createSession, let voiceController = environment.connection?.voice {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 28) {
                        welcomeHeader

                        if MachineStore.hasMultipleAgents(machines.launchableMachines) {
                            machinePicker(createSession)
                        } else if machines.loaded && machines.launchableMachines.isEmpty {
                            // The web has no equivalent warning — sending to an offline VM
                            // silently creates a row that queues. Worth surfacing rather than
                            // porting the gap.
                            Label("No machine is online right now.", systemImage: "exclamationmark.triangle.fill")
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.warningText)
                        }

                        if !createSession.availableSessionTypes.isEmpty {
                            sessionTypePicker(createSession)
                        }

                        if let dir = createSession.workingDir {
                            workingDirRow(dir, createSession)
                        } else if let sunkType = selectedSunkType(createSession) {
                            sunkTypeRow(sunkType)
                        }

                        if !createSession.availableSessionTypes.isEmpty {
                            modelPicker(createSession)
                        }

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.errorText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 24)
                }
                if ClaudeAuthPredicates.needsSignIn(claudeAuth.auth) {
                    signInBlockedRow
                } else {
                    composerBar(createSession, voiceController)
                }
            }
            .paiScreenBackground()
            .sheet(isPresented: $isPresentingDirectoryBrowser) {
                DirectoryBrowserView(
                    agent: createSession.selectedMachine, api: environment.connection?.apiClient,
                    environments: createSession.environmentSessionTypes
                ) { path in
                    createSession.selectWorkingDir(path)
                    drafts.selectWorkingDir(path)
                } onSelectEnvironment: { typeID in
                    createSession.selectWorkingDir(nil)
                    drafts.selectWorkingDir(nil)
                    createSession.selectSessionType(typeID)
                    drafts.selectSessionType(typeID)
                    isComposerFocused = true
                }
            }
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
                    onInsertTranscript: { prefixed in appendTranscript(prefixed) },
                    onAttach: { files in stageAttachments(files) }
                )
            }
        } else {
            ProgressView()
                .paiScreenBackground()
        }
    }

    // MARK: - Welcome header

    private var welcomeHeader: some View {
        VStack(spacing: 4) {
            Text("New Session")
                .font(PaiTypography.screenTitle.font)
                .foregroundStyle(PaiPalette.Semantic.textStrong)
            Text("What would you like to work on?")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Machine picker

    /// Only appears when there is a real choice — offline machines are absent, not disabled, the
    /// same rule the web's `AgentPicker` uses: a greyed control implies "maybe later," and there
    /// is nothing maybe-later about a machine that is not there right now.
    private func machinePicker(_ createSession: CreateSessionStore) -> some View {
        HStack(spacing: 8) {
            ForEach(machines.launchableMachines) { machine in
                let isSelected = createSession.selectedMachine == machine.slug
                Button {
                    createSession.selectMachine(machine.slug)
                    // Each machine's type list — and any browsed directory — is its own; carrying
                    // a persisted choice across a machine switch is the exact `bypassPermissions`
                    // wrong-checkout hazard `selectMachine`'s own doc comment describes. Matches
                    // the web's `NewSessionView.handleAgentChange` clearing both in the draft too.
                    drafts.selectWorkingDir(nil)
                    isComposerFocused = true
                } label: {
                    Text(machine.displayName)
                        .font(PaiTypography.bodyEmphasized.font)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                            in: Capsule()
                        )
                        .foregroundStyle(
                            isSelected ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textPrimary
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("machine-picker-\(machine.slug)")
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Session type picker

    /// Only the top-level types (home, fast, and any other ConfigMap-defined type) plus Custom —
    /// a built-in environment sinks into the Custom directory browser instead, below its
    /// favourites (`CreateSessionStore.sunkSessionTypeIds`'s doc comment).
    private func sessionTypePicker(_ createSession: CreateSessionStore) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(createSession.primarySessionTypes) { type in
                SessionTypeCard(type: type, isSelected: createSession.selectedSessionTypeId == type.id) {
                    createSession.selectSessionType(type.id)
                    drafts.selectSessionType(type.id)
                    isComposerFocused = true
                }
                .accessibilityIdentifier("session-type-\(type.id)")
            }
            SessionTypeCard(
                type: SessionType(id: "custom", name: "Custom", icon: "📁"),
                isSelected: createSession.selectedSessionTypeId == "custom"
                    || createSession.environmentSessionTypes.contains { $0.id == createSession.selectedSessionTypeId }
            ) {
                isPresentingDirectoryBrowser = true
            }
            .accessibilityIdentifier("session-type-custom")
        }
    }

    // MARK: - Model picker

    /// Mirrors the web's shared `ModelSelect.tsx`: a row of aliases, disabled (with the same
    /// reason shown beneath it) whenever `fast` is selected, since that sandbox always hardcodes
    /// its own model.
    private func modelPicker(_ createSession: CreateSessionStore) -> some View {
        let disabled = createSession.selectedSessionTypeId == CreateSessionStore.preselectedSessionTypeId
        return VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(CreateSessionStore.modelOptions, id: \.label) { option in
                    let isSelected = createSession.selectedModel == option.id
                    Button {
                        createSession.selectModel(option.id)
                        drafts.selectModel(option.id)
                        isComposerFocused = true
                    } label: {
                        Text(option.label)
                            .font(PaiTypography.captionEmphasized.font)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                isSelected ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                                in: Capsule()
                            )
                            .foregroundStyle(
                                isSelected ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textPrimary
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(disabled)
                    .opacity(disabled ? 0.5 : 1)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    .accessibilityIdentifier("create-session-model-\(option.label.lowercased())")
                }
            }
            if disabled {
                Text("Fast sessions always run Sonnet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
    }

    private func workingDirRow(_ dir: String, _ createSession: CreateSessionStore) -> some View {
        HStack {
            Text(dir)
                .font(PaiTypography.monoLabel.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Change") { isPresentingDirectoryBrowser = true }
                .buttonStyle(.borderless)
                .font(PaiTypography.caption.font)
            Button("Clear") {
                createSession.selectWorkingDir(nil)
                drafts.selectWorkingDir(nil)
            }
            .buttonStyle(.borderless)
            .font(PaiTypography.caption.font)
        }
    }

    /// A sunk environment (picked from inside the Custom browser) has no pill of its own — the
    /// Custom pill reads as selected for it too, and this row is what shows which one, mirroring
    /// the web's own row for the same case.
    private func selectedSunkType(_ createSession: CreateSessionStore) -> SessionType? {
        createSession.environmentSessionTypes.first { $0.id == createSession.selectedSessionTypeId }
    }

    private func sunkTypeRow(_ type: SessionType) -> some View {
        HStack {
            Text("\(type.icon) \(type.name)")
                .font(PaiTypography.monoLabel.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Spacer()
            Button("Change") { isPresentingDirectoryBrowser = true }
                .buttonStyle(.borderless)
                .font(PaiTypography.caption.font)
        }
    }

    // MARK: - Composer

    /// A session started without a working credential does not fail — it launches, never
    /// registers with Remote Control, and sits spinning until a timeout blames the connection.
    /// So the composer is replaced rather than greyed out, matching the web's `NewSessionView`.
    ///
    /// The real `ClaudeAuthBanner`, not a message pointing back at it — this screen is presented
    /// as a sheet, so the app-wide banner mounted above `RootView`'s own `NavigationStack` is
    /// underneath it and out of sight for exactly as long as this is on screen. Sign-in has to be
    /// actionable from here, not just named as being somewhere else.
    private var signInBlockedRow: some View {
        ClaudeAuthBanner()
            .padding(.vertical, 8)
    }

    /// The same shape `ComposerBar`'s drivable composer uses, over the same `DraftKey.newSession`
    /// draft, minus the Cancel action (`hasSession: false` — nothing is running yet).
    private func composerBar(_ createSession: CreateSessionStore, _ voiceController: VoiceRecorderController)
        -> some View
    {
        VStack(spacing: 6) {
            if isRecordingHere(voiceController) {
                VoiceRecordingIndicator(controller: voiceController)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !stagedAttachments.isEmpty {
                AttachmentPreviewStrip(attachments: stagedAttachments, onRemove: removeAttachment)
            }

            // Same left-to-right order as `ComposerBar`: field, plus, mic, send. Two composers
            // that look alike and put their controls in different places is worse than either
            // arrangement on its own.
            HStack(alignment: .bottom, spacing: 8) {
                ComposerTextEditor(
                    text: textBinding, height: $textHeight, placeholder: "What would you like to work on?",
                    scrollToTailOnNextUpdate: $scrollToTailOnNextUpdate,
                    onPasteImages: { images in
                        stageAttachments(
                            images.map {
                                AttachmentCompression.stage(
                                    data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
                            })
                    }
                )
                .focused($isComposerFocused)
                .frame(height: textHeight)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("new-session-message")

                ComposerActionMenu(
                    hasSession: false,
                    onPastRecordings: { showingRecordingsSheet = true },
                    onAddPhoto: { showingPhotoPicker = true },
                    onAddFile: { showingFilePicker = true },
                    onTemporaryNote: { showingTemporaryNote = true },
                    onCancel: {}
                )

                VoiceRecorderButton(
                    controller: voiceController,
                    isMine: voiceController.state == .idle || isRecordingHere(voiceController)
                ) {
                    Task { await toggleRecording(voiceController: voiceController) }
                }

                if isRecordingHere(voiceController) {
                    MuteButton(controller: voiceController) { voiceController.toggleMute() }
                } else {
                    sendButton(createSession)
                }
            }
        }
        // The recorder runs here with no draft key (see `isRecordingHere`'s doc comment), so
        // unlike `ComposerBar` the live transcript has to be polled into the draft here rather
        // than arriving already written. `.task(id:)` rather than a free-standing `Task` so it
        // keeps running across `.paused`/`.reconnecting` but stops with the view, instead of
        // outliving it once per visit.
        .task(id: isRecordingHere(voiceController)) {
            guard isRecordingHere(voiceController) else { return }
            var lastPartial = ""
            while !Task.isCancelled, voiceController.state != .idle {
                let partial = voiceController.transcribedText
                if partial != lastPartial {
                    lastPartial = partial
                    drafts.setDraftText(
                        key: DraftKey.newSession,
                        text: VoiceRecorderController.composeLiveText(pre: preVoiceText, partial: partial))
                    scrollToTailOnNextUpdate = true
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func sendButton(_ createSession: CreateSessionStore) -> some View {
        Button {
            send(createSession)
        } label: {
            if createSession.isCreating {
                ProgressView()
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(canSend(createSession) ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
            }
        }
        .disabled(!canSend(createSession) || createSession.isCreating)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("create-session-send")
    }

    private func canSend(_ createSession: CreateSessionStore) -> Bool {
        !createSession.isCreating
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !stagedAttachments.isEmpty)
    }

    private func send(_ createSession: CreateSessionStore) {
        let messageText = text
        let attachmentsSnapshot = stagedAttachments
        let files = attachmentsSnapshot.map {
            PaiFileUpload(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
        }
        if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.saveSentMessage(messageText)
        }
        Task {
            errorMessage = nil
            switch await createSession.create(message: messageText, files: files) {
            case .created(let session):
                sessionList.prependOptimisticSession(session)
                // Same "clear only once it is truly sent" rule `ComposerBar` follows: nothing
                // here undoes this on failure, since the failure branch below never reaches it.
                drafts.clearDraft(key: DraftKey.newSession)
                staging.set([], for: DraftKey.newSession)
                // Push before dismissing. A push onto the stack behind a sheet that is in the
                // middle of dismissing is dropped often enough to be a known iOS trap, and the
                // failure is silent: the session is created and the user stays on the list,
                // looking at a row they have to tap again.
                environment.router.push(.session(id: session.id))
                dismiss()
            case .failed(let message):
                // The draft is kept — text and attachments stay exactly where they were, matching
                // the web: a failure here should never cost what was already staged.
                errorMessage = message
            }
        }
    }

    // MARK: - Attachments

    private func removeAttachment(_ attachment: StagedAttachment) {
        staging.remove(id: attachment.id, from: DraftKey.newSession)
    }

    /// The one entry point every attachment source funnels through — a 50MB file discovered here
    /// fails immediately with a named reason, matching `ComposerBar`'s own guard.
    private func stageAttachments(_ staged: [StagedAttachment]) {
        let oversize = staged.filter { $0.currentSize > maxAttachmentBytes }
        let accepted = staged.filter { $0.currentSize <= maxAttachmentBytes }
        staging.append(accepted, to: DraftKey.newSession)
        if let first = oversize.first {
            let suffix = oversize.count > 1 ? " and \(oversize.count - 1) other file(s)" : ""
            errorMessage = "\(first.filename)\(suffix) exceeds the 50MB limit and was not attached."
        }
    }

    // MARK: - Text / drafts

    /// See `ComposerBar.textBinding`'s own doc comment for why the draft store is the field's
    /// only storage — the same reasoning applies here.
    private var textBinding: Binding<String> {
        Binding(
            get: { drafts.draft(for: DraftKey.newSession).text },
            set: { newValue in drafts.setDraftText(key: DraftKey.newSession, text: newValue) }
        )
    }

    private var text: String {
        drafts.draft(for: DraftKey.newSession).text
    }

    private var stagedAttachments: [StagedAttachment] {
        staging.attachments(for: DraftKey.newSession)
    }

    // MARK: - Voice

    /// This sheet's take is the one the shared recorder is running with no draft key — see
    /// `start(draftKey:preText:)`. Anything else belongs to a session's composer.
    private func isRecordingHere(_ controller: VoiceRecorderController) -> Bool {
        controller.activeDraftKey == nil && controller.state != .idle
    }

    private func toggleRecording(voiceController: VoiceRecorderController) async {
        guard voiceController.state == .idle || isRecordingHere(voiceController) else {
            errorMessage = "A recording is already running somewhere else."
            return
        }
        switch voiceController.state {
        case .idle:
            preVoiceText = text
            // No draft key: the recorder itself never touches `DraftStore` for this take, so the
            // transcript is polled into it explicitly above rather than arriving already written
            // the way the chat composer's does.
            await voiceController.start(draftKey: nil, preText: text)
        case .recording, .connecting, .paused, .reconnecting:
            // A tap always means "end the take", regardless of which of these mid-take states it
            // caught — `VoiceRecordingSession.stop` accepts all of them. Same rule as
            // `ComposerBar`'s own record button: one control, one behaviour, on both screens.
            let finalText = await voiceController.stop()
            applyVoiceResult(finalText)
        case .stopping:
            break
        }
    }

    private func applyVoiceResult(_ prefixedText: String) {
        guard !prefixedText.isEmpty else {
            drafts.setDraftText(key: DraftKey.newSession, text: preVoiceText)
            return
        }
        let combined = preVoiceText.isEmpty ? prefixedText : "\(preVoiceText) \(prefixedText)"
        drafts.setDraftText(key: DraftKey.newSession, text: combined)
    }

    private func appendTranscript(_ prefixedText: String) {
        let combined = text.isEmpty ? prefixedText : "\(text) \(prefixedText)"
        drafts.setDraftText(key: DraftKey.newSession, text: combined)
    }
}

/// One session-type or "Custom" pill, presented as an icon card — the phone-friendly shape
/// Android already uses for this picker (`SessionTypeCard`), kept for its presentation only; the
/// selection and preselection rules underneath are the web's, verbatim.
private struct SessionTypeCard: View {
    let type: SessionType
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(type.icon)
                    .font(.system(size: 28))
                Text(type.name)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 76)
            .padding(8)
            .background(
                isSelected ? PaiPalette.Semantic.accentBackground : PaiPalette.Semantic.raisedSurface,
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isSelected ? PaiPalette.primary500 : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
