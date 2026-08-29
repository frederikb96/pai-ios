import PAIKit
import SwiftUI

/// A full-screen sheet rather than the web's centred modal: a 12-row monospace text area inside a
/// small dialog does not survive a phone's keyboard, and this is the one composer surface that
/// wants the whole screen given to typing. The byte-count footer and the disabled-until-non-empty
/// Attach rule are kept exactly as the web has them.
struct TemporaryNoteSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filename = ""
    @State private var content = ""
    @FocusState private var contentFocused: Bool

    let onAttach: (StagedAttachment) -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Stays on the VM with this session's other attachments, readable only by Kai's user.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)

                TextField("note.txt", text: $filename)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Note filename")

                TextEditor(text: $content)
                    .font(PaiTypography.markdownCodeBlock.font)
                    .focused($contentFocused)
                    .scrollContentBackground(.hidden)
                    .background(PaiPalette.Semantic.raisedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxHeight: .infinity)
                    .accessibilityLabel("Note content")
            }
            .padding()
            .navigationTitle("Temporary note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Attach") {
                        onAttach(TemporaryNote.makeFile(name: filename, content: content))
                        dismiss()
                    }
                    .disabled(content.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    if !content.isEmpty {
                        Text(formatFileSize(content.utf8.count))
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            }
        }
        .onAppear { contentFocused = true }
        .accessibilityIdentifier("temporary-note-sheet")
    }
}
