import PAIKit
import SwiftUI

/// The editable markdown surface.
///
/// Split from `NoteEditorScreen` because the two answer different questions: the screen owns
/// navigation, saving and what the note *is*, and this owns text, caret and layout. The
/// block-based rendering that gives fenced code and tables their own horizontal scroll region
/// replaces the inside of this type without the screen changing.
struct NoteEditorSurface: View {
    let text: String
    let onChange: (String) -> Void

    @State private var draft: String = ""

    var body: some View {
        TextEditor(text: draftBinding)
            .font(PaiTypography.markdownBody.font)
            .foregroundStyle(PaiPalette.Semantic.textPrimary)
            .scrollContentBackground(.hidden)
            .background(PaiPalette.Semantic.screenBackground)
            .padding(.horizontal, 12)
            .task(id: text) {
                // Adopt the incoming text only when it is genuinely different from what is on
                // screen. Assigning unconditionally would move the caret to the end on every
                // keystroke, because each one comes back through `text`.
                if draft != text { draft = text }
            }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { draft },
            set: { newValue in
                draft = newValue
                onChange(newValue)
            }
        )
    }
}
