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
    let text: String
    /// Changes when the body was replaced by something other than typing — see
    /// ``NotesStore/externalBodyRevision``. The editor rebuilds from this rather than from `text`,
    /// because `text` also comes back changed from a save that normalised anything at all.
    let revision: Int
    let jump: NoteJumpRequest?
    let onChange: (String) -> Void

    @State private var document: NoteEditorDocument
    @State private var focusedID: UUID?
    @State private var caret: PlacedCaret?
    @State private var caretToken = 0
    /// What this view last handed upwards. Compared against an incoming `text` to tell "the note
    /// reloaded from the server" from "this is our own edit coming back", which must not rebuild
    /// the document under the caret.
    @State private var lastPublished: String

    init(text: String, revision: Int, jump: NoteJumpRequest?, onChange: @escaping (String) -> Void) {
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
                        onFocus: { focusedID = item.id }
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
        .onChange(of: revision) { adoptIfChangedElsewhere() }
        .onChange(of: jump) { _, request in goTo(request) }
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

    private func focusBelowTheLastRegion() {
        if let target = document.appendTrailingProse() {
            move(to: target)
            publish()
        } else {
            focusedID = document.items.last?.id
        }
    }

    private func goTo(_ request: NoteJumpRequest?) {
        guard let request, let target = document.locate(characterOffset: request.characterOffset) else { return }
        move(to: target)
    }

    private func move(to target: NoteEditorDocument.CaretTarget) {
        caretToken += 1
        focusedID = target.itemID
        caret = PlacedCaret(itemID: target.itemID, request: CaretRequest(token: caretToken, offset: target.offset))
    }

    private func publish() {
        lastPublished = document.source
        onChange(lastPublished)
    }

    /// Take on a body that arrived from somewhere other than this view — a first load, a restored
    /// revision, a conflict resolved in favour of the vault.
    ///
    /// Still guarded on the text actually differing: the note is reloaded whenever the tools panel
    /// refreshes, and rebuilding the document for a body that came back identical would destroy
    /// the caret for nothing.
    private func adoptIfChangedElsewhere() {
        guard text != lastPublished else { return }
        document = NoteEditorDocument(source: text)
        lastPublished = text
        caret = nil
        focusedID = nil
    }
}

/// A caret request plus which region it belongs to. Separate from ``CaretRequest`` because the
/// text view is handed only the part that concerns it.
private struct PlacedCaret: Equatable {
    let itemID: UUID
    let request: CaretRequest
}
