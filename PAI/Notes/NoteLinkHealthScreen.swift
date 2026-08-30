import PAIKit
import SwiftUI

/// The whole broken-links screen for one container in one answer — a view only; nothing here is
/// ever acted on automatically, matching the web (`note_link_health_route`'s own doc comment).
struct NoteLinkHealthScreen: View {
    let containerId: String

    @Environment(NotesStore.self) private var notes
    @Environment(AppEnvironment.self) private var environment

    @State private var health: NoteLinkHealth?
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
            } else if let health {
                issueSection("Broken links", issues: health.broken)
                issueSection("Links outside the container", issues: health.outside)

                if !health.unlinkedAttachments.isEmpty {
                    Section("Unlinked attachments") {
                        ForEach(health.unlinkedAttachments) { attachment in
                            Text(attachment.basename).foregroundStyle(PaiPalette.Semantic.textPrimary)
                        }
                    }
                }
                if !health.unlinkedNotes.isEmpty {
                    Section("Unlinked notes") {
                        ForEach(health.unlinkedNotes) { note in
                            Button {
                                environment.router.push(.note(id: note.id))
                            } label: {
                                Text(note.name.isEmpty ? "Untitled" : note.name)
                                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                            }
                        }
                    }
                }
                if !health.ambiguousNames.isEmpty {
                    Section("Ambiguous names") {
                        ForEach(health.ambiguousNames, id: \.self) { name in
                            Text(name).foregroundStyle(PaiPalette.Semantic.textPrimary)
                        }
                    } footer: {
                        Text(
                            "Shared by more than one note in this container — a wikilink resolving to one of them may not reach the one you meant."
                        )
                    }
                }
                if health.broken.isEmpty && health.outside.isEmpty && health.unlinkedAttachments.isEmpty
                    && health.unlinkedNotes.isEmpty && health.ambiguousNames.isEmpty
                {
                    Text("No issues found.").foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            } else {
                ProgressView()
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Link health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
    }

    @ViewBuilder
    private func issueSection(_ title: String, issues: [NoteLinkIssue]) -> some View {
        if !issues.isEmpty {
            Section(title) {
                ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.sourceNoteName.isEmpty ? "Untitled" : issue.sourceNoteName)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        Text(issue.rawTarget)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            }
        }
    }

    private func reload() async {
        do {
            health = try await notes.loadLinkHealth(containerId: containerId)
            error = nil
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? "Could not load link health"
        }
    }
}
