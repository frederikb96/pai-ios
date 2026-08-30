import PAIKit
import SwiftUI

/// The editable markdown surface: one region per stretch of the note that shares a wrapping
/// behaviour, stacked.
///
/// The design is in ``NoteSegment``'s own documentation, and the short version is that regions
/// exist only where they have to: around fenced code and tables, which scroll sideways while
/// everything else wraps. A note with no code is one text view, and editing it is entirely
/// UIKit's own behaviour.
struct NoteEditorSurface: View {
    let text: String
    let onChange: (String) -> Void

    @State private var document: NoteEditorDocument
    @State private var focusedID: UUID?
    @State private var caret: NoteEditorDocument.CaretTarget?
    /// What this view last handed upwards. Compared against an incoming `text` to tell "the note
    /// reloaded from the server" from "this is our own edit coming back", which must not rebuild
    /// the document under the caret.
    @State private var lastPublished: String

    init(text: String, onChange: @escaping (String) -> Void) {
        self.text = text
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
                        caretOffset: caret?.itemID == item.id ? caret?.offset : nil,
                        onChange: { edited(item.id, $0) },
                        onDeleteBackwardAtStart: { mergeBackward(from: item.id) },
                        onFocus: { focusedID = item.id }
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            // Tapping the empty space under the last region puts the caret in it, which is what a
            // page of text does. Without it the bottom of a short note is dead space.
            .background {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focusedID = document.items.last?.id }
            }
        }
        .background(PaiPalette.Notes.background)
        .task(id: text) { adoptIfChangedElsewhere() }
    }

    private func edited(_ id: UUID, _ displayText: String) {
        let moved = document.edit(id: id, displayText: displayText)
        if let moved {
            focusedID = moved.itemID
            caret = moved
        } else {
            // Cleared rather than left standing: a caret target is an instruction to move the
            // caret, and one that outlived the restructure that produced it would drag the caret
            // back on the next keystroke.
            caret = nil
        }
        publish()
    }

    private func mergeBackward(from id: UUID) -> Bool {
        guard let target = document.mergeBackward(from: id) else { return false }
        focusedID = target.itemID
        caret = target
        publish()
        return true
    }

    private func publish() {
        lastPublished = document.source
        onChange(lastPublished)
    }

    /// Take on a body that arrived from somewhere other than this view — a first load, or a
    /// conflict resolved in favour of the vault.
    ///
    /// Guarded on it actually differing from what was last published, because the note's body
    /// flows back down through the store on every keystroke. Rebuilding on that would destroy the
    /// caret roughly sixty times a minute.
    private func adoptIfChangedElsewhere() {
        guard text != lastPublished else { return }
        document = NoteEditorDocument(source: text)
        lastPublished = text
        caret = nil
        focusedID = nil
    }
}
