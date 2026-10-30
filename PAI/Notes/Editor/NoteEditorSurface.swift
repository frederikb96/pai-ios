import PAIKit
import SwiftUI

/// Somewhere in the note the editor has been asked to go — an outline heading, a search hit.
///
/// Tokenised for the same reason ``CaretRequest`` is: the same heading tapped twice is the same
/// offset twice, and a plain offset would look unchanged and do nothing the second time.
struct NoteJumpRequest: Equatable {
    let token: Int
    /// A Character offset into the whole note body, which is what the outline and the in-note
    /// search both count in.
    let characterOffset: Int
}

/// The editable markdown surface: the whole note in one wrapping text view.
///
/// Fenced code and tables lay out inside it rather than in a region of their own — see
/// ``MarkdownSourceTextView``'s own documentation for why, and what that removed.
struct NoteEditorSurface: View {
    let noteID: String
    /// See ``MarkdownSourceTextView/text``.
    let text: () -> String
    /// Changes when the body was replaced by something other than typing — see
    /// ``NotesStore/externalBodyRevision``. The editor rebuilds from this rather than from `text`,
    /// because `text` also comes back changed from a save that normalised anything at all.
    let revision: Int
    /// Keeps the reader's position and reaches the text still inside the view.
    let handle: NoteEditorHandle
    let jump: NoteJumpRequest?
    /// What the in-note search is looking for, painted across the note — see
    /// ``MarkdownSourceTextView/highlight``.
    let highlight: String?
    /// Whether the screen has a sheet up over this editor — the outline/links/history panel or
    /// the actions sheet, neither of which resigns the editor's first responder status on its
    /// own. Folded into the text view's effective focus below, alongside this view's own local
    /// sheets (the attachment picker), rather than left to the text view to guess: without it, a
    /// store update the sheet's own reload triggers rebuilds this screen, and the hidden text
    /// view — still holding first-responder status from before the sheet opened, or reclaiming it
    /// on the rebuild — steals the keyboard (and any keystrokes) right back from the sheet.
    let isCoveredBySheet: Bool
    let onChange: (String) -> Void

    @Environment(NotesStore.self) private var notes
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts

    @State private var isFocused = false
    @State private var caret: CaretRequest?
    @State private var caretToken = 0
    @State private var insertion: NoteInsertion?
    @State private var insertionToken = 0
    /// A large note is being painted and laid out, which is shown rather than left blank.
    @State private var isPreparing = false

    /// Where an attachment picked from the keyboard bar has to land — a UTF-16 offset into the
    /// note. Captured when the paperclip is tapped rather than read afterwards: presenting a
    /// picker takes the keyboard away, and the selection with it.
    @State private var attachmentOffset: Int?
    @State private var isChoosingAttachment = false
    @State private var isPickingPhoto = false
    @State private var isPickingFile = false
    @State private var isUploading = false

    init(
        noteID: String, text: @escaping () -> String, revision: Int, handle: NoteEditorHandle, jump: NoteJumpRequest?,
        highlight: String?, isCoveredBySheet: Bool, onChange: @escaping (String) -> Void
    ) {
        self.noteID = noteID
        self.text = text
        self.revision = revision
        self.handle = handle
        self.jump = jump
        self.highlight = highlight
        self.isCoveredBySheet = isCoveredBySheet
        self.onChange = onChange
    }

    /// Every sheet that covers this view, whether presented by the screen above or by this view's
    /// own attachment flow — see ``isCoveredBySheet``.
    private var isCovered: Bool {
        isCoveredBySheet || isChoosingAttachment || isPickingPhoto || isPickingFile
    }

    var body: some View {
        MarkdownSourceTextView(
            text: text, revision: revision, isFocused: isFocused && !isCovered, caret: caret, insertion: insertion,
            highlight: highlight, toolbarLayout: settings.noteToolbarLayout,
            showsLineNumbers: settings.showsNoteLineNumbers, handle: handle,
            onChange: onChange,
            onFocus: { isFocused = true },
            onAttach: { offset in beginAttachment(at: offset) },
            onPasteImages: { offset, images in pasteImages(images, at: offset) },
            onLoadingChange: { isPreparing = $0 },
            onReplaced: {
                caret = nil
                isFocused = false
            }
        )
        .background(PaiPalette.Notes.background)
        .overlay {
            if isPreparing { ProgressView("Opening…") }
        }
        .overlay(alignment: .top) {
            if isUploading {
                ProgressView("Uploading…")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 8)
            }
        }
        .onChange(of: jump) { _, request in goTo(request) }
        .confirmationDialog("Add to this note", isPresented: $isChoosingAttachment, titleVisibility: .visible) {
            Button("Photo") { isPickingPhoto = true }
            Button("File") { isPickingFile = true }
            Button("Cancel", role: .cancel) { attachmentOffset = nil }
        }
        .sheet(isPresented: $isPickingPhoto) {
            PhotoAttachmentPicker { staged in Task { await upload(staged) } }
        }
        .sheet(isPresented: $isPickingFile) {
            FileAttachmentPicker { staged in Task { await upload(staged) } }
        }
    }

    private func goTo(_ request: NoteJumpRequest?) {
        guard let request else { return }
        let body = text()
        let clamped = min(max(request.characterOffset, 0), body.count)
        move(to: String(body.prefix(clamped)).utf16.count, settlingAtTopThird: true)
    }

    private func move(to utf16Offset: Int, settlingAtTopThird: Bool = false) {
        caretToken += 1
        isFocused = true
        caret = CaretRequest(token: caretToken, offset: utf16Offset, settlesAtTopThird: settlingAtTopThird)
    }

    // MARK: Attachments

    private func beginAttachment(at offset: Int) {
        guard notes.detail(for: noteID)?.containerId != nil else {
            toasts.show("This note has no container, so there is nowhere to put a file", kind: .error)
            return
        }
        guard !notes.isOffline else {
            toasts.show(NoteOnlineOnly.addFile.message, kind: .error)
            return
        }
        attachmentOffset = offset
        isChoosingAttachment = true
    }

    /// A paste that carried an image — the same paste path the session composer already offers,
    /// through `MarkdownSourceTextView/onPasteImages`'s own doc comment on why. `AttachmentCompression`
    /// is the composer's own re-encode (HEIC included), reused rather than duplicated; the actual
    /// upload is `upload(_:)` below, unchanged from what the paperclip already drives — a paste is
    /// simply another way to arrive at the same offset `beginAttachment(at:)` captures from a tap.
    private func pasteImages(_ images: [PastedImage], at offset: Int) {
        guard notes.detail(for: noteID)?.containerId != nil else {
            toasts.show("This note has no container, so there is nowhere to put a file", kind: .error)
            return
        }
        guard !notes.isOffline else {
            toasts.show(NoteOnlineOnly.addFile.message, kind: .error)
            return
        }
        attachmentOffset = offset
        let staged = images.map {
            AttachmentCompression.stage(data: $0.data, filename: $0.filename, mimeType: $0.mimeType)
        }
        Task { await upload(staged) }
    }

    /// Uploads what was picked and writes an embed for each file at the caret.
    ///
    /// The whole batch becomes one edit rather than one per file, so Undo takes them back together
    /// and the autosave debounce sees a single change.
    private func upload(_ staged: [StagedAttachment]) async {
        guard let offset = attachmentOffset, let containerId = notes.detail(for: noteID)?.containerId,
            !staged.isEmpty
        else { return }
        attachmentOffset = nil
        isUploading = true
        defer { isUploading = false }

        var embeds: [String] = []
        for file in staged {
            do {
                let uploaded = try await notes.uploadAttachment(
                    containerId: containerId, filename: file.filename, mimeType: file.mimeType, data: file.data)
                embeds.append("![[\(uploaded.relPath)]]")
            } catch {
                toasts.show(
                    NoteSyncFailure.isTransport(error)
                        ? NoteOnlineOnly.addFile.message : "Could not upload \(file.filename)", kind: .error)
            }
        }
        guard !embeds.isEmpty else { return }
        insert(embeds.joined(separator: "\n"), atUtf16: offset)
    }

    /// Goes through the text view, so Undo takes it back and the text typed since the offset was
    /// captured is not lost to a stale copy of the note.
    private func insert(_ snippet: String, atUtf16 offset: Int) {
        insertionToken += 1
        isFocused = true
        insertion = NoteInsertion(token: insertionToken, offset: offset, snippet: snippet)
    }
}
