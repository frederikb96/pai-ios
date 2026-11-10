import PAIKit
import SwiftUI

/// The "No memory" mark on a session row, the session header and the new-session screen.
struct NoMemoryPill: View {
    var body: some View {
        Label(NoMemoryCopy.toggleLabel, systemImage: "eye.slash")
            .labelStyle(.titleAndIcon)
            .font(PaiTypography.captionEmphasized.font)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(PaiPalette.Semantic.raisedSurface, in: Capsule())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("no-memory-pill")
    }
}

/// The small explanation behind the picker's info button.
struct NoMemoryInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(NoMemoryCopy.infoParagraphs, id: \.self) { paragraph in
                        Text(paragraph).font(PaiTypography.body.font)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .navigationTitle(NoMemoryCopy.infoTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("no-memory-info-done")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("no-memory-info-sheet")
    }
}
