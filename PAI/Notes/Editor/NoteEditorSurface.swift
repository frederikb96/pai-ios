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

/// The editable markdown surface: one region per stretch of the note that shares a wrapping
/// behaviour, stacked.
///
/// The design is in ``NoteSegment``'s own documentation, and the short version is that regions
/// exist only where they have to: around fenced code and tables, which scroll sideways while
/// everything else wraps. A note with no code is one text view, and editing it is entirely
/// UIKit's own behaviour.
struct NoteEditorSurface: View {
    let noteID: String
    let text: String
    /// Changes when the body was replaced by something other than typing — see
    /// ``NotesStore/externalBodyRevision``. The editor rebuilds from this rather than from `text`,
    /// because `text` also comes back changed from a save that normalised anything at all.
    let revision: Int
    let jump: NoteJumpRequest?
    let onChange: (String) -> Void

    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var document: NoteEditorDocument
    @State private var focusedID: UUID?
    @State private var caret: PlacedCaret?
    @State private var caretToken = 0
    /// What this view last handed upwards. Compared against an incoming `text` to tell "the note
    /// reloaded from the server" from "this is our own edit coming back", which must not rebuild
    /// the document under the caret.
    @State private var lastPublished: String

    /// Where an attachment picked from the keyboard bar has to land. Captured when the paperclip
    /// is tapped rather than read afterwards: presenting a picker takes the keyboard away, and the
    /// selection with it.
    @State private var attachmentLanding: AttachmentLanding?
    @State private var isChoosingAttachment = false
    @State private var isPickingPhoto = false
    @State private var isPickingFile = false
    @State private var isUploading = false

    init(noteID: String, text: String, revision: Int, jump: NoteJumpRequest?, onChange: @escaping (String) -> Void) {
        self.noteID = noteID
        self.text = text
        self.revision = revision
        self.jump = jump
        self.onChange = onChange
        _document = State(initialValue: NoteEditorDocument(source: text))
        _lastPublished = State(initialValue: text)
    }

    var body: some View {
        ScrollView(.vertical) {
            // Not lazy. A lazy stack destroys a region's view when it scrolls out of sight, which
            // for an editor means losing the first responder — and with it the keyboard and the
            // caret — because the reader scrolled. A note is a handful of regions, so there is
            // nothing to gain by deferring them.
            VStack(alignment: .leading, spacing: 2) {
                ForEach(document.items) { item in
                    MarkdownSourceTextView(
                        text: item.displayText,
                        kind: item.kind,
                        isFocused: focusedID == item.id,
                        caret: caret?.itemID == item.id ? caret?.request : nil,
                        onChange: { edited(item.id, $0) },
                        onDeleteBackwardAtStart: { mergeBackward(from: item.id) },
                        onFocus: { focusedID = item.id },
                        onAttach: { offset in beginAttachment(in: item.id, at: offset) }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Tapping under the last region puts the caret in it, which is what a page of text
                // does — and a note whose last region is a code block gets a paragraph to type in,
                // since otherwise there is nowhere below the block at all. Sized rather than
                // painted behind the stack: a background is exactly as tall as the content, so the
                // empty space this exists to catch is the one place it would not be.
                Color.clear
                    .contentShape(Rectangle())
                    .frame(height: 140)
                    .onTapGesture { focusBelowTheLastRegion() }
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
            Button("Cancel", role: .cancel) { attachmentLanding = nil }
        }
        .sheet(isPresented: $isPickingPhoto) {
            PhotoAttachmentPicker { staged in Task { await upload(staged) } }
        }
        .sheet(isPresented: $isPickingFile) {
            FileAttachmentPicker { staged in Task { await upload(staged) } }
        }
    }

    private func edited(_ id: UUID, _ displayText: String) {
        if let moved = document.edit(id: id, displayText: displayText) {
            move(to: moved)
        } else {
            // Cleared rather than left standing: a caret request is an instruction to move the
            // caret, and one that outlived the restructure that produced it would drag the caret
            // back on the next redraw.
            caret = nil
        }
        publish()
    }

    private func mergeBackward(from id: UUID) -> Bool {
        guard let target = document.mergeBackward(from: id) else { return false }
        move(to: target)
        publish()
        return true
    }

    /// Deliberately does not publish. Adding the paragraph changes the note by one newline, and a
    /// tap that is followed by nothing must not rewrite a file — so the region exists on screen
    /// while the note on disk is untouched, and the first keystroke publishes both together.
    /// Backspacing straight out of it removes the region again and publishes nothing at all.
    private func focusBelowTheLastRegion() {
        if let target = document.appendTrailingProse() {
            move(to: target)
        } else {
            focusedID = document.items.last?.id
        }
    }

    private func goTo(_ request: NoteJumpRequest?) {
        guard let request, let target = document.locate(characterOffset: request.characterOffset) else { return }
        move(to: target, settlingAtTopThird: true)
    }

    private func move(to target: NoteEditorDocument.CaretTarget, settlingAtTopThird: Bool = false) {
        caretToken += 1
        focusedID = target.itemID
        caret = PlacedCaret(
            itemID: target.itemID,
            request: CaretRequest(
                token: caretToken, offset: target.offset, settlesAtTopThird: settlingAtTopThird))
    }

    private func publish() {
        lastPublished = document.source
        onChange(lastPublished)
    }

    // MARK: Attachments

    private func beginAttachment(in itemID: UUID, at offset: Int) {
        guard notes.detail(for: noteID)?.containerId != nil else {
            toasts.show("This note has no container, so there is nowhere to put a file", kind: .error)
            return
        }
        attachmentLanding = AttachmentLanding(itemID: itemID, offset: offset)
        isChoosingAttachment = true
    }

    /// Uploads what was picked and writes an embed for each file at the caret.
    ///
    /// The whole batch becomes one edit rather than one per file, so Undo takes them back together
    /// and the autosave debounce sees a single change.
    private func upload(_ staged: [StagedAttachment]) async {
        guard let landing = attachmentLanding, let containerId = notes.detail(for: noteID)?.containerId,
            !staged.isEmpty
        else { return }
        attachmentLanding = nil
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
        insert(embeds.joined(separator: "\n"), into: landing.itemID, atUtf16: landing.offset)
    }

    private func insert(_ snippet: String, into itemID: UUID, atUtf16 offset: Int) {
        guard let index = document.index(of: itemID) else { return }
        let edited = NSMutableString(string: document.items[index].displayText)
        let at = min(max(offset, 0), edited.length)
        edited.insert(snippet, at: at)
        if let moved = document.edit(id: itemID, displayText: edited as String) {
            move(to: moved)
        } else {
            move(to: .init(itemID: itemID, offset: at + snippet.utf16.count))
        }
        publish()
    }

    /// Take on a body that arrived from somewhere other than this view — a first load, a restored
    /// revision, a conflict resolved in favour of the vault.
    ///
    /// Still guarded on the text actually differing: the note is reloaded whenever the tools panel
    /// refreshes, and rebuilding the document for a body that came back identical would destroy
    /// the caret.
    private func adoptIfChangedElsewhere() {
        guard text != lastPublished else { return }
        document = NoteEditorDocument(source: text)
        lastPublished = text
        caret = nil
        focusedID = nil
    }
}

/// Where an attachment picked from the keyboard bar goes back to.
private struct AttachmentLanding: Equatable {
    let itemID: UUID
    /// UTF-16 offset within that region's display text.
    let offset: Int
}

/// A caret request plus which region it belongs to. Separate from ``CaretRequest`` because the
/// text view is handed only the part that concerns it.
private struct PlacedCaret: Equatable {
    let itemID: UUID
    let request: CaretRequest
}
