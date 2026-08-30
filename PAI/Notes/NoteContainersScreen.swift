import PAIKit
import SwiftUI

/// Which directories on which machines are synced as notes.
struct NoteContainersScreen: View {
    @Environment(NotesStore.self) private var notes

    var body: some View {
        List(notes.containers) { container in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(container.name)
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    if container.isDefault {
                        Text("default")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.accentText)
                    }
                    Spacer(minLength: 0)
                    Text(container.state)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                Text("\(container.agentSlug) · \(container.path)")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(2)
                if let error = container.lastError, !error.isEmpty {
                    Text(error)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
            .padding(.vertical, 4)
            .listRowBackground(PaiPalette.Semantic.panelBackground)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .paiScreenBackground()
        .navigationTitle("Containers")
        .task { await notes.refreshContainers() }
        .refreshable { await notes.refreshContainers() }
    }
}
