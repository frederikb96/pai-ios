import PAIKit
import SwiftUI

/// The note index (spec parity with `pai-cloud/web/src/apps/notes/NoteList.tsx`): client-side
/// filter-as-you-type over the already-loaded index, favourites and tags narrowing it further,
/// and a full-text mode that reaches the server for a literal substring match over note bodies.
///
/// Semantic search is deliberately out of scope here — it needs a `/api/memory/search`-shaped
/// route and a shared relative-threshold slider this app has no equivalent of yet, and porting
/// those is a separate piece of work from the notes module itself.
struct NoteListScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var filterText = ""
    @State private var favouritesOnly = false
    @State private var selectedTags: [String] = []
    @State private var mode: Mode = .filter
    @State private var debouncedQuery = ""

    @State private var searchResults: [NoteSearchHit] = []
    @State private var searchTruncated = false
    @State private var searchLoading = false
    @State private var searchError: String?

    @State private var actionsTargetId: String?
    @State private var previewTargetId: String?

    private enum Mode: Equatable { case filter, fullText }

    var body: some View {
        list
            .paiScreenBackground()
            .navigationTitle("Notes")
            .searchable(text: $filterText, prompt: mode == .fullText ? "Search note text" : "Filter notes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        environment.router.push(.noteContainers)
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Note containers")
                    .accessibilityIdentifier("open-note-containers")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            guard let created = await notes.createNote(name: "Untitled") else {
                                toasts.show(notes.loadError ?? "Could not create the note", kind: .error)
                                return
                            }
                            environment.router.push(.note(id: created.id))
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New note")
                }
            }
            .task {
                guard notes.notes.isEmpty else { return }
                await notes.refresh()
            }
            .refreshable { await notes.refresh() }
            .task(id: filterText) {
                guard mode == .fullText else { return }
                let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    searchResults = []
                    searchTruncated = false
                    return
                }
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { return }
                await runFullTextSearch(trimmed)
            }
            .sheet(item: Binding(get: { actionsTargetId.map(NoteId.init) }, set: { actionsTargetId = $0?.value })) {
                target in
                NoteActionsSheet(
                    noteId: target.value, onOpenNote: { environment.router.push(.note(id: $0)) },
                    // Nothing is open to put a caret in, so a heading tapped from here opens the
                    // note — at the top, which is where opening a note lands anyway.
                    onJumpTo: { _ in environment.router.push(.note(id: target.value)) })
            }
            .sheet(item: Binding(get: { previewTargetId.map(NoteId.init) }, set: { previewTargetId = $0?.value })) {
                target in
                NavigationStack {
                    NoteBodyView(
                        body: notes.detail(for: target.value)?.body ?? "",
                        nameToId: buildNameToId(notes.notes), containerId: notes.detail(for: target.value)?.containerId
                    )
                    .navigationTitle(
                        notes.summary(for: target.value)?.name.isEmpty == false
                            ? notes.summary(for: target.value)!.name : "Untitled"
                    )
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close") { previewTargetId = nil }
                        }
                    }
                    .task { await notes.loadNote(id: target.value) }
                }
            }
    }

    @ViewBuilder
    private var list: some View {
        VStack(spacing: 0) {
            filterChips
            Group {
                if let error = notes.loadError, notes.notes.isEmpty {
                    ContentUnavailableView(
                        "Notes unavailable", systemImage: "exclamationmark.triangle", description: Text(error))
                } else if mode == .fullText {
                    fullTextResults
                } else if visibleNotes.isEmpty && !notes.isLoading {
                    ContentUnavailableView(
                        "No notes", systemImage: "note.text",
                        description: Text(
                            filterText.isEmpty && !favouritesOnly
                                ? "Notes synced from a container appear here." : "No notes match"))
                } else {
                    List(visibleNotes) { note in
                        row(for: note)
                    }
                    .listStyle(.plain)
                }
            }
        }
    }

    private var filterChips: some View {
        HStack(spacing: 8) {
            Button {
                mode = mode == .fullText ? .filter : .fullText
                filterText = ""
                searchResults = []
            } label: {
                Label("Full text", systemImage: "text.magnifyingglass")
                    .font(PaiTypography.caption.font)
            }
            .buttonStyle(.bordered)
            .tint(mode == .fullText ? PaiPalette.primary500 : PaiPalette.Semantic.textMuted)

            if mode == .filter {
                Button {
                    favouritesOnly.toggle()
                } label: {
                    Label("Favourites", systemImage: favouritesOnly ? "star.fill" : "star")
                        .font(PaiTypography.caption.font)
                }
                .buttonStyle(.bordered)
                .tint(favouritesOnly ? PaiPalette.amber500 : PaiPalette.Semantic.textMuted)
            }

            tagMenu

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var tagMenu: some View {
        let options = collectTags(notes.notes.filter { !$0.pendingDelete })
        return Menu {
            ForEach(options) { option in
                Button {
                    if selectedTags.contains(option.key) {
                        selectedTags.removeAll { $0 == option.key }
                    } else {
                        selectedTags.append(option.key)
                    }
                } label: {
                    Label(
                        "\(option.label) (\(option.count))",
                        systemImage: selectedTags.contains(option.key) ? "checkmark" : "")
                }
            }
            if !selectedTags.isEmpty {
                Divider()
                Button("Clear tags") { selectedTags = [] }
            }
        } label: {
            Label(selectedTags.isEmpty ? "Tags" : "Tags (\(selectedTags.count))", systemImage: "tag")
                .font(PaiTypography.caption.font)
        }
        .disabled(options.isEmpty)
    }

    @ViewBuilder
    private func row(for note: NoteSummary) -> some View {
        Button {
            environment.router.push(.note(id: note.id))
        } label: {
            NoteRow(note: note)
        }
        .buttonStyle(.plain)
        .listRowBackground(PaiPalette.Semantic.panelBackground)
        .swipeActions(edge: .leading) {
            Button {
                Task { await notes.setFavourite(id: note.id, favourite: !note.favourite) }
            } label: {
                Label(note.favourite ? "Unfavourite" : "Favourite", systemImage: "star")
            }
            .tint(PaiPalette.amber500)
        }
        .swipeActions(edge: .trailing) {
            Button {
                actionsTargetId = note.id
            } label: {
                Label("Actions", systemImage: "ellipsis.circle")
            }
            .tint(PaiPalette.primary500)
        }
        .contextMenu {
            Button {
                previewTargetId = note.id
            } label: {
                Label("Preview", systemImage: "eye")
            }
            Button {
                actionsTargetId = note.id
            } label: {
                Label("Rename, delete & more…", systemImage: "ellipsis.circle")
            }
        }
    }

    private func runFullTextSearch(_ query: String) async {
        searchLoading = true
        searchError = nil
        defer { searchLoading = false }
        do {
            let page = try await notes.searchNotes(q: query)
            searchResults = page.hits
            searchTruncated = page.truncated
        } catch {
            searchError = (error as? PaiError)?.userMessage ?? "Search failed"
        }
    }

    @ViewBuilder
    private var fullTextResults: some View {
        if let searchError {
            ContentUnavailableView(
                "Search failed", systemImage: "exclamationmark.triangle", description: Text(searchError))
        } else if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search note text", systemImage: "text.magnifyingglass",
                description: Text("Type to search across every note's body."))
        } else if searchResults.isEmpty && !searchLoading {
            ContentUnavailableView("No matches", systemImage: "text.magnifyingglass")
        } else {
            List {
                if searchTruncated {
                    Text("More matches than shown — narrow the search.")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(searchResults.filter { noteHasAllTags($0.note, selected: selectedTags) }) { hit in
                    Button {
                        environment.router.push(.note(id: hit.note.id))
                    } label: {
                        NoteSearchHitRow(hit: hit)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(PaiPalette.Semantic.panelBackground)
                }
                if searchLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
        }
    }

    private var visibleNotes: [NoteSummary] {
        let live = notes.notes.filter { !$0.pendingDelete }
        let scoped = favouritesOnly ? live.filter(\.favourite) : live
        let tagged = scoped.filter { noteHasAllTags($0, selected: selectedTags) }
        let filtered =
            filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? tagged : tagged.filter { noteMatchesQuery($0, query: filterText) }
        return filtered.sorted { $0.updatedAtMs > $1.updatedAtMs }
    }
}

/// `.sheet(item:)` needs an `Identifiable` value; a bare `String?` id can't drive it directly.
private struct NoteId: Identifiable {
    let value: String
    var id: String { value }
}

private struct NoteRow: View {
    let note: NoteSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.name.isEmpty ? "Untitled" : note.name)
                    .font(PaiTypography.bodyEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                if let summary = note.summary, !summary.isEmpty {
                    Text(summary)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if note.favourite {
                Image(systemName: "star.fill")
                    .foregroundStyle(PaiPalette.amber500)
            }
        }
        .padding(.vertical, 4)
        // A row laid out with a `Spacer()` is hit-tested against what it draws, so the empty
        // width beside the text would ignore a tap without this.
        .contentShape(Rectangle())
    }
}

private struct NoteSearchHitRow: View {
    let hit: NoteSearchHit

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hit.note.name.isEmpty ? "Untitled" : hit.note.name)
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
            Text(hit.extract)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .lineLimit(3)
            if hit.matchCount > 1 {
                Text("\(hit.matchCount) matches")
                    .font(.system(size: 10))
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
