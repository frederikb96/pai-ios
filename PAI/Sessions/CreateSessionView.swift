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

    @State private var createSession: CreateSessionStore?
    @State private var voiceController: VoiceRecorderController?
    @State private var isPresentingDirectoryBrowser = false
    @State private var errorMessage: String?

    // MARK: - Composer state
    //
    // Deliberately local rather than a `DraftStore` sync — see `CreateSessionStore`'s doc comment
    // on why the "new" draft's launch-choice half is never synced independently of the text half.

    @State private var text = ""
    @State private var textHeight: CGFloat = ComposerTextEditor.minHeight
    @State private var scrollToTailOnNextUpdate = false
    @State private var preVoiceText = ""
    @State private var stagedAttachments: [StagedAttachment] = []
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
        .task {
            guard createSession == nil, let connection = environment.connection else { return }
            let store = CreateSessionStore(machines: machines, api: connection.apiClient)
            createSession = store
            voiceController = VoiceRecorderController(
                apiClient: connection.apiClient, settingsStore: connection.settings)
            // Freshest possible online/offline picture at the moment stakes are highest: a
            // session about to launch on whichever machine turns out to be reachable.
            await machines.refresh()
            await store.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let createSession, let voiceController {
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
                composerBar(createSession, voiceController)
            }
            .paiScreenBackground()
            .sheet(isPresented: $isPresentingDirectoryBrowser) {
                DirectoryBrowserView(agent: createSession.selectedMachine, api: environment.connection?.apiClient) {
                    path in
                    createSession.selectWorkingDir(path)
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

    private func sessionTypePicker(_ createSession: CreateSessionStore) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
            ForEach(createSession.availableSessionTypes) { type in
                SessionTypeCard(type: type, isSelected: createSession.selectedSessionTypeId == type.id) {
                    createSession.selectSessionType(type.id)
                    isComposerFocused = true
                }
                .accessibilityIdentifier("session-type-\(type.id)")
            }
            SessionTypeCard(
                type: SessionType(id: "custom", name: "Custom", icon: "📁"),
                isSelected: createSession.selectedSessionTypeId == "custom"
            ) {
                isPresentingDirectoryBrowser = true
            }
            .accessibilityIdentifier("session-type-custom")
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
            Button("Clear") { createSession.selectWorkingDir(nil) }
                .buttonStyle(.borderless)
                .font(PaiTypography.caption.font)
        }
    }

    // MARK: - Composer

    /// The same shape `ComposerBar`'s drivable composer uses, minus drafts (out of scope, see
    /// this type's doc comment) and minus the Cancel action (`hasSession: false` — nothing is
    /// running yet).
    private func composerBar(_ createSession: CreateSessionStore, _ voiceController: VoiceRecorderController)
        -> some View
    {
        VStack(spacing: 6) {
            VoiceRecordingIndicator(controller: voiceController)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !stagedAttachments.isEmpty {
                AttachmentPreviewStrip(attachments: stagedAttachments, onRemove: removeAttachment)
            }

            HStack(alignment: .bottom, spacing: 8) {
                ComposerActionMenu(
                    hasSession: false,
                    onPastRecordings: { showingRecordingsSheet = true },
                    onAddPhoto: { showingPhotoPicker = true },
                    onAddFile: { showingFilePicker = true },
                    onTemporaryNote: { showingTemporaryNote = true },
                    onCancel: {}
                )

                ComposerTextEditor(
                    text: $text, height: $textHeight, placeholder: "What would you like to work on?",
                    scrollToTailOnNextUpdate: $scrollToTailOnNextUpdate
                )
                .focused($isComposerFocused)
                .frame(height: textHeight)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .accessibilityIdentifier("new-session-message")

                if voiceController.state == .recording || voiceController.state == .stopping {
                    MuteButton(controller: voiceController) { voiceController.toggleMute() }
                } else {
                    sendButton(createSession)
                }

                VoiceRecorderButton(controller: voiceController) {
                    Task { await toggleRecording(voiceController: voiceController) }
                }
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
        stagedAttachments.removeAll { $0.id == attachment.id }
    }

    /// The one entry point every attachment source funnels through — a 50MB file discovered here
    /// fails immediately with a named reason, matching `ComposerBar`'s own guard.
    private func stageAttachments(_ staged: [StagedAttachment]) {
        let oversize = staged.filter { $0.currentSize > maxAttachmentBytes }
        let accepted = staged.filter { $0.currentSize <= maxAttachmentBytes }
        stagedAttachments.append(contentsOf: accepted)
        if let first = oversize.first {
            let suffix = oversize.count > 1 ? " and \(oversize.count - 1) other file(s)" : ""
            errorMessage = "\(first.filename)\(suffix) exceeds the 50MB limit and was not attached."
        }
    }

    // MARK: - Voice

    private func toggleRecording(voiceController: VoiceRecorderController) async {
        switch voiceController.state {
        case .idle:
            preVoiceText = text
            await voiceController.start()
            observeLiveTranscript(voiceController: voiceController)
        case .recording, .connecting:
            let finalText = await voiceController.stop()
            applyVoiceResult(finalText)
        case .stopping:
            break
        }
    }

    private func observeLiveTranscript(voiceController: VoiceRecorderController) {
        Task {
            var lastPartial = ""
            while voiceController.state == .connecting || voiceController.state == .recording {
                let partial = voiceController.transcribedText
                if partial != lastPartial {
                    lastPartial = partial
                    text = Self.composeLiveText(pre: preVoiceText, partial: partial)
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

    private func applyVoiceResult(_ prefixedText: String) {
        guard !prefixedText.isEmpty else {
            text = preVoiceText
            return
        }
        text = preVoiceText.isEmpty ? prefixedText : "\(preVoiceText) \(prefixedText)"
    }

    private func appendTranscript(_ prefixedText: String) {
        text = text.isEmpty ? prefixedText : "\(text) \(prefixedText)"
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
