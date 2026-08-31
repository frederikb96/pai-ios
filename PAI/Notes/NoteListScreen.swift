import PAIKit
import SwiftUI

/// The note index (spec parity with `pai-cloud/web/src/apps/notes/NoteList.tsx`): client-side
/// filter-as-you-type over the already-loaded index, favourites and tags narrowing it further,
/// a full-text mode that reaches the server for a literal substring match over note bodies, and a
/// semantic mode that reaches `POST /api/memory/search` for a meaning-based match over each
/// note's summary.
struct NoteListScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(NotesStore.self) private var notes
    @Environment(NotesBrowseStore.self) private var browse
    @Environment(ToastCenter.self) private var toasts

    @State private var filterText = ""
    @State private var favouritesOnly = false
    @State private var selectedTags: [String] = []
    @State private var mode: Mode = .filter
    @State private var showTagFilter = false

    @State private var searchResults: [NoteSearchHit] = []
    @State private var searchTruncated = false
    @State private var searchLoading = false
    @State private var searchError: String?

    @State private var semanticResults: [NoteSemanticHit] = []
    @State private var semanticLoading = false
    @State private var semanticError: String?

    @State private var actionsTargetId: String?
    @State private var previewTargetId: String?

    private enum Mode: Equatable { case filter, fullText, semantic }

    /// Drives the debounced search `.task` — one id covering both server-reaching modes so a
    /// mode switch and a keystroke are never two separate tasks racing each other.
    private struct SearchTrigger: Equatable {
        let query: String
        let mode: Mode
    }

    var body: some View {
        list
            .paiScreenBackground()
            .navigationTitle("Notes")
            .searchable(text: $filterText, prompt: searchPrompt)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Menu("Sort by") {
                            ForEach(NoteSortOrder.allCases) { order in
                                Button {
                                    browse.setSortOrder(order)
                                } label: {
                                    if browse.sortOrder == order {
                                        Label(order.label, systemImage: "checkmark")
                                    } else {
                                        Text(order.label)
                                    }
                                }
                            }
                        }
                        Divider()
                        Button {
                            environment.router.push(.noteContainers)
                        } label: {
                            Label("Containers", systemImage: "folder")
                        }
                        .accessibilityIdentifier("open-note-containers")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("Note list actions")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await createNote() }
                        } label: {
                            Label("New note", systemImage: "square.and.pencil")
                        }
                        Button {
                            environment.router.push(.noteContainers)
                        } label: {
                            Label("New container", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Create")
                }
            }
            .task {
                guard notes.notes.isEmpty else { return }
                await notes.refresh()
            }
            .refreshable { await notes.refresh() }
            .task(id: SearchTrigger(query: filterText, mode: mode)) {
                guard mode == .fullText || mode == .semantic else { return }
                let trimmed = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    searchResults = []
                    searchTruncated = false
                    semanticResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { return }
                if mode == .fullText {
                    await runFullTextSearch(trimmed)
                } else {
                    await runSemanticSearch(trimmed)
                }
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

    private var searchPrompt: String {
        switch mode {
        case .filter: return "Filter notes"
        case .fullText: return "Search note text"
        case .semantic: return "Search by meaning"
        }
    }

    private func createNote() async {
        guard let created = await notes.createNote(name: "Untitled") else {
            toasts.show(notes.loadError ?? "Could not create the note", kind: .error)
            return
        }
        environment.router.push(.note(id: created.id))
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
                } else if mode == .semantic {
                    semanticResultsView
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
            modeChip(target: .fullText, label: "Full text", systemImage: "text.magnifyingglass")
            modeChip(target: .semantic, label: "Semantic", systemImage: "sparkles")

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

            tagFilterButton

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func modeChip(target: Mode, label: String, systemImage: String) -> some View {
        Button {
            mode = mode == target ? .filter : target
            filterText = ""
            searchResults = []
            semanticResults = []
        } label: {
            Label(label, systemImage: systemImage)
                .font(PaiTypography.caption.font)
        }
        .buttonStyle(.bordered)
        .tint(mode == target ? PaiPalette.primary500 : PaiPalette.Semantic.textMuted)
    }

    private var tagFilterButton: some View {
        let options = collectTags(notes.notes.filter { !$0.pendingDelete })
        return Button {
            showTagFilter = true
        } label: {
            Label(selectedTags.isEmpty ? "Tags" : "Tags (\(selectedTags.count))", systemImage: "tag")
                .font(PaiTypography.caption.font)
        }
        .buttonStyle(.bordered)
        .tint(selectedTags.isEmpty ? PaiPalette.Semantic.textMuted : PaiPalette.primary500)
        .disabled(options.isEmpty)
        .sheet(isPresented: $showTagFilter) {
            NoteTagFilterSheet(options: options, selected: $selectedTags)
        }
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
        // One edge, two buttons: the outer one (listed first) is the full-swipe default. A
        // small swipe reaches Actions first since it sits nearer the row's content; continuing
        // to a full swipe triggers Favourite without a tap, since it owns the edge.
        .swipeActions(edge: .trailing) {
            Button {
                Task { await notes.setFavourite(id: note.id, favourite: !note.favourite) }
            } label: {
                Label(note.favourite ? "Unfavourite" : "Favourite", systemImage: "star")
            }
            .tint(PaiPalette.amber500)

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

    private func runSemanticSearch(_ query: String) async {
        semanticLoading = true
        semanticError = nil
        defer { semanticLoading = false }
        do {
            semanticResults = try await browse.searchSemantic(q: query)
        } catch {
            semanticError = (error as? PaiError)?.userMessage ?? "Search failed"
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

    @ViewBuilder
    private var semanticResultsView: some View {
        if let semanticError {
            ContentUnavailableView(
                "Search failed", systemImage: "exclamationmark.triangle", description: Text(semanticError))
        } else if filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Search by meaning", systemImage: "sparkles",
                description: Text("Type to search notes by what they mean, not just their words."))
        } else if semanticVisible.isEmpty && !semanticLoading {
            ContentUnavailableView("No matches", systemImage: "sparkles")
        } else {
            List {
                ForEach(semanticVisible) { entry in
                    Button {
                        environment.router.push(.note(id: entry.note.id))
                    } label: {
                        NoteRow(note: entry.note, score: entry.hit.score)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(PaiPalette.Semantic.panelBackground)
                }
                if semanticLoading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .listStyle(.plain)
        }
    }

    /// Every semantic hit resolved against the already-loaded index — the search route answers
    /// only an id and a score (see `NotesBrowseStore`'s doc comment), never a name or summary
    /// that could go stale relative to what a note holds now.
    private var semanticVisible: [SemanticNoteHit] {
        let byId = Dictionary(
            uniqueKeysWithValues: notes.notes.filter { !$0.pendingDelete }.map { ($0.id, $0) })
        return semanticResults.compactMap { hit in
            guard let note = byId[hit.noteId], noteHasAllTags(note, selected: selectedTags) else { return nil }
            return SemanticNoteHit(hit: hit, note: note)
        }
    }

    private var visibleNotes: [NoteSummary] {
        let live = notes.notes.filter { !$0.pendingDelete }
        let scoped = favouritesOnly ? live.filter(\.favourite) : live
        let tagged = scoped.filter { noteHasAllTags($0, selected: selectedTags) }
        let filtered =
            filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? tagged : tagged.filter { noteMatchesQuery($0, query: filterText) }
        return sortNotes(filtered, order: browse.sortOrder)
    }
}

/// `.sheet(item:)` needs an `Identifiable` value; a bare `String?` id can't drive it directly.
private struct NoteId: Identifiable {
    let value: String
    var id: String { value }
}

/// A semantic hit resolved against the already-loaded index — see `semanticVisible`'s own doc
/// comment. `Identifiable` by note id, the same identity `ForEach` uses for the plain index list.
private struct SemanticNoteHit: Identifiable {
    let hit: NoteSemanticHit
    let note: NoteSummary
    var id: String { hit.noteId }
}

/// The row's timestamp — pure presentation over `SessionListFormat.timeBucket`, which is the
/// tested half; picking a `Date.FormatStyle` template per bucket is left to the view on purpose
/// (see that type's own doc comment). Mirrors the session list's own `SessionTimeFormat` rather
/// than a third convention, since both read the same three buckets.
private enum NoteTimeFormat {
    static func text(for updatedAtMs: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(updatedAtMs) / 1000)
        switch SessionListFormat.timeBucket(for: date) {
        case .today:
            return date.formatted(date: .omitted, time: .shortened)
        case .thisWeek:
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        case .older:
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}

private struct NoteRow: View {
    let note: NoteSummary
    var score: Double? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(note.name.isEmpty ? "Untitled" : note.name)
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    if let score {
                        Text("\(Int((score * 100).rounded()))%")
                            .font(.system(size: 10))
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(NoteTimeFormat.text(for: note.updatedAtMs))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                    if let summary = note.summary, !summary.isEmpty {
                        Text(summary)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                            .lineLimit(2)
                    }
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
            highlightedExtract
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

    /// Reuses the transcript's own search-highlight painting (`TranscriptTextHighlighting`,
    /// `TranscriptSearchPainting`) so a note's full-text hits look the same as a highlighted
    /// transcript hit rather than a second, differently-coloured convention.
    private var highlightedExtract: Text {
        let highlights: [TranscriptHighlightSpan] = NoteExtractHighlight.ranges(
            extract: hit.extract, offsets: hit.extractOffsets
        ).map { ($0, false) }
        return TranscriptTextHighlighting.plainText(
            hit.extract, font: PaiTypography.caption.font, highlights: highlights)
    }
}
