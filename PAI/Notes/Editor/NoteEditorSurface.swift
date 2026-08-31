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
    let text: String
    /// Changes when the body was replaced by something other than typing — see
    /// ``NotesStore/externalBodyRevision``. The editor rebuilds from this rather than from `text`,
    /// because `text` also comes back changed from a save that normalised anything at all.
    let revision: Int
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
    @Environment(ToastCenter.self) private var toasts

    @State private var isFocused = false
    @State private var caret: CaretRequest?
    @State private var caretToken = 0
    /// What this view last handed upwards. Compared against an incoming `text` to tell "the note
    /// reloaded from the server" from "this is our own edit coming back", which must not disturb
    /// the caret.
    @State private var lastPublished: String

    /// Where an attachment picked from the keyboard bar has to land — a UTF-16 offset into the
    /// note. Captured when the paperclip is tapped rather than read afterwards: presenting a
    /// picker takes the keyboard away, and the selection with it.
    @State private var attachmentOffset: Int?
    @State private var isChoosingAttachment = false
    @State private var isPickingPhoto = false
    @State private var isPickingFile = false
    @State private var isUploading = false

    init(
        noteID: String, text: String, revision: Int, jump: NoteJumpRequest?, highlight: String?,
        isCoveredBySheet: Bool, onChange: @escaping (String) -> Void
    ) {
        self.noteID = noteID
        self.text = text
        self.revision = revision
        self.jump = jump
        self.highlight = highlight
        self.isCoveredBySheet = isCoveredBySheet
        self.onChange = onChange
        _lastPublished = State(initialValue: text)
    }

    /// Every sheet that covers this view, whether presented by the screen above or by this view's
    /// own attachment flow — see ``isCoveredBySheet``.
    private var isCovered: Bool {
        isCoveredBySheet || isChoosingAttachment || isPickingPhoto || isPickingFile
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                MarkdownSourceTextView(
                    text: text, isFocused: isFocused && !isCovered, caret: caret, highlight: highlight,
                    onChange: { edited($0) },
                    onFocus: { isFocused = true },
                    onAttach: { offset in beginAttachment(at: offset) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                // Tapping under the note puts the caret at its end, which is what a page of text
                // does. Sized rather than painted behind the stack: a background is exactly as
                // tall as the content, so the empty space this exists to catch is the one place
                // it would not be.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(height: 140)
                    .onTapGesture { focusAtEnd() }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(PaiPalette.Notes.background)
        .overlay(alignment: .top) {
            if isUploading {
                ProgressView("Uploading…")
                    .padding(10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding(.top, 8)
            }
        }
        .onChange(of: revision) { adoptIfChangedElsewhere() }
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

    private func edited(_ newText: String) {
        // Cleared rather than left standing: a caret request is an instruction to move the caret,
        // and one that outlived the keystroke that produced it would drag the caret back on the
        // next redraw.
        caret = nil
        publish(newText)
    }

    private func focusAtEnd() {
        move(to: text.utf16.count)
        isFocused = true
    }

    private func goTo(_ request: NoteJumpRequest?) {
        guard let request else { return }
        let clamped = min(max(request.characterOffset, 0), text.count)
        move(to: String(text.prefix(clamped)).utf16.count, settlingAtTopThird: true)
    }

    private func move(to utf16Offset: Int, settlingAtTopThird: Bool = false) {
        caretToken += 1
        isFocused = true
        caret = CaretRequest(token: caretToken, offset: utf16Offset, settlesAtTopThird: settlingAtTopThird)
    }

    private func publish(_ newText: String) {
        lastPublished = newText
        onChange(newText)
    }

    // MARK: Attachments

    private func beginAttachment(at offset: Int) {
        guard notes.detail(for: noteID)?.containerId != nil else {
            toasts.show("This note has no container, so there is nowhere to put a file", kind: .error)
            return
        }
        attachmentOffset = offset
        isChoosingAttachment = true
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
                toasts.show("Could not upload \(file.filename)", kind: .error)
            }
        }
        guard !embeds.isEmpty else { return }
        insert(embeds.joined(separator: "\n"), atUtf16: offset)
    }

    private func insert(_ snippet: String, atUtf16 offset: Int) {
        let mutable = NSMutableString(string: text)
        let at = min(max(offset, 0), mutable.length)
        mutable.insert(snippet, at: at)
        move(to: at + snippet.utf16.count)
        publish(mutable as String)
    }

    /// Take on a body that arrived from somewhere other than this view — a first load, a restored
    /// revision, a conflict resolved in favour of the vault.
    ///
    /// Still guarded on the text actually differing: the note is reloaded whenever the tools panel
    /// refreshes, and rebuilding under a body that came back identical would destroy the caret.
    private func adoptIfChangedElsewhere() {
        guard text != lastPublished else { return }
        lastPublished = text
        caret = nil
        isFocused = false
    }
}
