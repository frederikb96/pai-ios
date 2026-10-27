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
/// the top-level home/fast pair (`CreateSessionStore.environmentSessionTypes`): tapping Custom shows the directory favourites first, then a section for the other
/// environments. Picking one is not a directory choice at all, so it routes
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
            VStack(spacing: 0) {
                filterField
                Divider()
                browserList(store)
            }
        } else {
            ProgressView()
        }
    }

    private func browserList(_ store: DirectoryBrowserStore) -> some View {
        List {
            if !store.filteredFavorites.isEmpty {
                Section("Favorites") {
                    ForEach(store.filteredFavorites) { favorite in
                        favoriteRow(store, favorite)
                    }
                }
            }

            let visibleEnvironments = store.filteredEnvironments(environments)
            if !visibleEnvironments.isEmpty {
                Section("Environments") {
                    ForEach(visibleEnvironments) { type in
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
    }

    /// Tapping the name picks the favourite and closes the sheet, like the web; the chevron
    /// opens it as the folder being browsed instead.
    private func favoriteRow(_ store: DirectoryBrowserStore, _ favorite: FolderFavorite) -> some View {
        HStack {
            Button {
                onSelect(favorite.path)
                dismiss()
            } label: {
                Label {
                    // Truncated from the start, matching the web's `direction: rtl` trick — the
                    // last path segment is what identifies a folder, so that is what must
                    // survive truncation.
                    Text(SessionListFormat.basename(favorite.path))
                        .lineLimit(1)
                        .truncationMode(.head)
                } icon: {
                    Image(systemName: "star.fill")
                        .foregroundStyle(PaiPalette.amber500)
                }
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                Task { await store.navigateToFavorite(favorite.path) }
            } label: {
                Image(systemName: "chevron.right")
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(SessionListFormat.basename(favorite.path))")
        }
        .contentShape(Rectangle())
        .accessibilityIdentifier("directory-browser-favorite-\(favorite.path)")
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PaiPalette.Semantic.textFaint)
            if let store {
                TextField("Filter this list", text: filterBinding(store))
                    .textFieldStyle(.plain)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityIdentifier("directory-browser-filter")
                if !store.filterText.isEmpty {
                    Button {
                        store.filterText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear filter")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
