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
    @Environment(SettingsStore.self) private var settings
    @Environment(ToastCenter.self) private var toasts

    @State private var isFocused = false
    @State private var caret: CaretRequest?
    @State private var caretToken = 0
    /// Where the page's `ScrollView` sits. Written continuously from ``onScrollGeometryChange``
    /// below, and read back once on ``onAppear`` to command a jump — `ScrollPosition`'s own
    /// `x`/`y` go `nil` the moment the reader scrolls by hand, so it is a one-shot "go here", not
    /// a live readout, and ``lastOffsetY`` is what actually remembers the position.
    ///
    /// Kept as this view's own `@State` rather than in a cross-screen store keyed by note id: a
    /// plain SwiftUI `ScrollView` loses its offset when covered and revealed again on a
    /// `NavigationStack` — the underlying `UIScrollView` can be torn down and rebuilt even though
    /// this view's own state survives the round trip — and this binding is the first-party
    /// mechanism for carrying a position across exactly that. A raw point rather than an anchored
    /// id: nothing above the reader can change height while this note is off screen, unlike the
    /// feed the ``scrolling`` skill warns against pixel offsets for, so "the exact position it
    /// was left" is literally what a raw offset captures here.
    @State private var scrollPosition = ScrollPosition()
    /// The live vertical offset, updated on every scroll — this is what survives being covered
    /// and revealed, and what ``scrollPosition`` is set from on reappearance.
    @State private var lastOffsetY: CGFloat = 0
    /// Fed by `MarkdownSourceTextView.onLineMetrics` — see that property's own doc comment for
    /// why it stops computing entirely, rather than merely not drawing, while the gutter is off.
    @State private var lineMetrics = NoteLineMetrics.empty
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
                // The gutter is an ordinary sibling here, not a synced overlay — see
                // `NoteLineNumberGutter`'s own doc comment for why that is enough to keep it in
                // lockstep with the text view as this whole page scrolls, with no offset
                // observation of its own.
                HStack(alignment: .top, spacing: 0) {
                    if settings.showsNoteLineNumbers {
                        NoteLineNumberGutter(metrics: lineMetrics)
                    }
                    MarkdownSourceTextView(
                        text: text, isFocused: isFocused && !isCovered, caret: caret, highlight: highlight,
                        onChange: { edited($0) },
                        onFocus: { isFocused = true },
                        onAttach: { offset in beginAttachment(at: offset) },
                        onPasteImages: { offset, images in pasteImages(images, at: offset) },
                        onLineMetrics: settings.showsNoteLineNumbers ? { lineMetrics = $0 } : nil
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        .scrollPosition($scrollPosition)
        .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, newValue in
            lastOffsetY = newValue
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
        // Restores the position this note was left at, across being covered by a pushed screen
        // and revealed again by Back — see ``lastOffsetY``'s own doc comment for why a plain
        // `ScrollView` needs this at all. A fresh note has never scrolled, so this is a no-op the
        // first time a note is opened.
        .onAppear {
            guard lastOffsetY > 0 else { return }
            scrollPosition = ScrollPosition(x: 0, y: lastOffsetY)
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
