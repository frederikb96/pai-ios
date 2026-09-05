import PAIKit
import SwiftUI

/// The "Custom" working-directory picker — a modal over `CreateSessionView`.
///
/// Owns its own `DirectoryBrowserStore`, fixed to whichever machine the session will launch on:
/// every browsable path is a `/home/frederik/...` path that exists on both machines and means a
/// different tree on each, so browsing the wrong one silently points a session at the wrong
/// checkout. `agent` is threaded in from the caller rather than read from anywhere shared.
///
/// Below the favourites it also lists whatever `environments` names — every session type beyond
/// the top-level home/fast pair (`CreateSessionStore.environmentSessionTypes`), per Freddy's own
/// wording: tapping Custom shows the directory favourites first, then a section for "other custom
/// environments where I can click on." Picking one is not a directory choice at all, so it routes
/// through `onSelectEnvironment` rather than `onSelect`.
struct DirectoryBrowserView: View {
    @Environment(\.dismiss) private var dismiss

    let agent: String?
    let api: PaiApiClient?
    var environments: [SessionType] = []
    let onSelect: (String) -> Void
    var onSelectEnvironment: (String) -> Void = { _ in }

    @State private var store: DirectoryBrowserStore?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Choose a Folder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Select") {
                            if let store {
                                onSelect(store.currentPath)
                            }
                            dismiss()
                        }
                        .disabled(store == nil)
                        .accessibilityIdentifier("directory-browser-select")
                    }
                }
        }
        .task {
            guard store == nil, let api else { return }
            let newStore = DirectoryBrowserStore(agent: agent, api: api)
            store = newStore
            await newStore.start()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let store {
            List {
                Section {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                        TextField("Filter", text: filterBinding(store))
                            .textFieldStyle(.plain)
                            .accessibilityIdentifier("directory-browser-filter")
                    }
                }

                if !store.sortedFavorites.isEmpty {
                    Section("Favorites") {
                        ForEach(store.sortedFavorites) { favorite in
                            Button {
                                Task { await store.navigateToFavorite(favorite.path) }
                            } label: {
                                Label {
                                    // Truncated from the start, matching the web's `direction:
                                    // rtl` trick — the last path segment is what identifies a
                                    // folder, so that is what must survive truncation.
                                    Text(SessionListFormat.basename(favorite.path))
                                        .lineLimit(1)
                                        .truncationMode(.head)
                                } icon: {
                                    Image(systemName: "star.fill")
                                        .foregroundStyle(PaiPalette.amber500)
                                }
                            }
                        }
                    }
                }

                if !environments.isEmpty {
                    Section("Environments") {
                        ForEach(environments) { type in
                            Button {
                                onSelectEnvironment(type.id)
                                dismiss()
                            } label: {
                                Label {
                                    Text(type.name)
                                } icon: {
                                    Text(type.icon)
                                }
                            }
                            .accessibilityIdentifier("directory-browser-environment-\(type.id)")
                        }
                    }
                }

                Section {
                    if store.canGoUp {
                        Button {
                            Task { await store.navigateUp() }
                        } label: {
                            Label("..", systemImage: "arrow.up.doc")
                        }
                        .accessibilityIdentifier("directory-browser-up")
                    }

                    ForEach(store.filteredDirectories, id: \.self) { directory in
                        directoryRow(store, directory)
                    }

                    if store.filteredDirectories.isEmpty && !store.isLoading {
                        Text(
                            store.filterText.isEmpty
                                ? "No subdirectories" : "No directories match \"\(store.filterText)\""
                        )
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                } header: {
                    HStack(spacing: 4) {
                        Text(store.currentPath)
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer()
                        Button {
                            Task { await store.toggleFavorite(store.currentPath) }
                        } label: {
                            Image(systemName: store.currentPathIsFavorite ? "star.fill" : "star")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            store.currentPathIsFavorite ? "Remove from favorites" : "Add to favorites"
                        )
                        .accessibilityIdentifier("directory-browser-favorite-current")
                    }
                }

                if let error = store.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
            }
            .overlay {
                if store.isLoading {
                    ProgressView()
                }
            }
        } else {
            ProgressView()
        }
    }

    private func directoryRow(_ store: DirectoryBrowserStore, _ directory: String) -> some View {
        let childPath = store.childPath(entering: directory)
        return HStack {
            Button {
                Task { await store.navigateInto(directory) }
            } label: {
                Label(directory, systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                Task { await store.toggleFavorite(childPath) }
            } label: {
                Image(systemName: store.isFavorite(childPath) ? "star.fill" : "star")
                    .foregroundStyle(PaiPalette.amber500)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("directory-browser-row-\(directory)")
    }

    private func filterBinding(_ store: DirectoryBrowserStore) -> Binding<String> {
        Binding(get: { store.filterText }, set: { store.filterText = $0 })
    }
}
