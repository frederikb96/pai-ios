import Observation
import PAIKit
import SwiftUI
import UIKit

/// Where the panel is sending the reader, and what it was looking for.
///
/// The query travels with the offset because the preview highlights every occurrence of it, and a
/// bare offset cannot say what was being searched for — or that this jump came from the outline,
/// where there is nothing to highlight at all.
struct NoteJumpTarget: Equatable {
    /// A Character offset into the note body.
    let characterOffset: Int
    let query: String?
}

/// What the tools panel remembers between openings.
///
/// Held by whatever presents the panel rather than by the panel itself, because a sheet's content
/// is built fresh every time it appears: kept inside, the tab resets to the outline, the search
/// box empties and a long outline is back at the top — so using the panel twice on one note means
/// finding the same place twice.
@Observable
final class NoteToolsPanelState {
    var tab: NoteToolsTab = .outline
    var query = ""
    /// The last entry jumped to from each list, so reopening lands on it rather than at the top.
    var lastOutlineOffset: Int?
    var lastSearchOffset: Int?
}

enum NoteToolsTab: CaseIterable, Hashable {
    case outline, search, backlinks, links, info, revisions

    var label: String {
        switch self {
        case .outline: "Outline"
        case .search: "Find in note"
        case .backlinks: "Backlinks"
        case .links: "Outgoing links"
        case .info: "Info"
        case .revisions: "History"
        }
    }

    var icon: String {
        switch self {
        case .outline: "list.bullet.indent"
        case .search: "magnifyingglass"
        case .backlinks: "arrow.up.left"
        case .links: "arrow.up.right"
        case .info: "info.circle"
        case .revisions: "clock.arrow.circlepath"
        }
    }
}

/// The iOS-native shape of the web's right-hand panel (`RightPanel.tsx`): outline, in-note
/// search, backlinks, outgoing links, note info and revision history — six tabs behind one icon
/// row, reached from `NoteActionsSheet` rather than docked beside an open editor, since a phone
/// has no room for both at once. Loads a snapshot on appearance rather than staying live, for the
/// same reason the web gives: cutting and pasting a link around should not disturb this list
/// while a note is being edited elsewhere.
struct NoteToolsPanel: View {
    let noteId: String
    let onOpenNote: (String) -> Void
    /// Where in the note the editor should go.
    let onJumpTo: (NoteJumpTarget) -> Void
    /// Survives the sheet being dismissed — see ``NoteToolsPanelState``.
    let state: NoteToolsPanelState

    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
        .paiNotesBackground()
        .navigationTitle("Outline, links & history")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await reload() }
    }

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(NoteToolsTab.allCases, id: \.self) { candidate in
                    Button {
                        state.tab = candidate
                    } label: {
                        Image(systemName: candidate.icon)
                            .frame(width: 36, height: 32)
                    }
                    .foregroundStyle(state.tab == candidate ? PaiPalette.primary700 : PaiPalette.Semantic.textMuted)
                    .background(
                        state.tab == candidate ? PaiPalette.primary50 : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityLabel(candidate.label)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state.tab {
        case .outline:
            // The body as it stands on screen, not the last one saved. They differ for as long as
            // the autosave debounce runs, and an outline that is one paragraph behind sends every
            // jump below it to the wrong place.
            NoteOutlineTab(body: notes.body(for: noteId) ?? "", state: state, onJumpTo: onJumpTo)
        case .search:
            NoteInNoteSearchTab(body: notes.body(for: noteId) ?? "", state: state, onJumpTo: onJumpTo)
        case .backlinks:
            NoteBacklinksTab(
                noteId: noteId, error: notes.linkGraphErrors[noteId], graph: notes.linkGraphs[noteId],
                onOpenNote: onOpenNote)
        case .links:
            NoteOutgoingLinksTab(
                noteId: noteId, notes: notes, toasts: toasts, error: notes.linkGraphErrors[noteId],
                graph: notes.linkGraphs[noteId], containerId: notes.detail(for: noteId)?.containerId,
                onOpenNote: onOpenNote, onReload: { await reload() })
        case .info:
            NoteInfoTab(noteId: noteId, notes: notes, toasts: toasts)
        case .revisions:
            NoteRevisionsTab(noteId: noteId, notes: notes, toasts: toasts)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        async let detail: Void = notes.loadNote(id: noteId)
        async let links: Void = notes.loadLinkGraph(id: noteId)
        _ = await (detail, links)
        // The editor underneath this sheet re-affirms its own first responder status whenever
        // its screen's body re-evaluates, and the two calls above are exactly the kind of
        // NotesStore update that triggers one — see NoteEditorScreen/NoteEditorSurface's
        // `focusedID`, which this sheet has no way to reach or reset directly. Resigning
        // whatever that just made first responder hands the keyboard back to a neutral state, so
        // a tap on one of this panel's own fields isn't fighting a UITextView it cannot see. Not
        // a full fix — see the outline/search focus row's report for what the real one needs.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Outline

private struct NoteOutlineTab: View {
    let noteBody: String
    let state: NoteToolsPanelState
    let onJumpTo: (NoteJumpTarget) -> Void

    init(body: String, state: NoteToolsPanelState, onJumpTo: @escaping (NoteJumpTarget) -> Void) {
        self.noteBody = body
        self.state = state
        self.onJumpTo = onJumpTo
    }

    var body: some View {
        let entries = parseOutline(noteBody)
        ScrollViewReader { proxy in
            List {
                if entries.isEmpty {
                    Text("No headings in this note.").foregroundStyle(PaiPalette.Semantic.textMuted)
                } else {
                    ForEach(entries) { entry in
                        Button {
                            state.lastOutlineOffset = entry.offset
                            onJumpTo(NoteJumpTarget(characterOffset: entry.offset, query: nil))
                        } label: {
                            Text(entry.text)
                                .padding(.leading, CGFloat(entry.level - 1) * 12)
                                .foregroundStyle(
                                    state.lastOutlineOffset == entry.offset
                                        ? PaiPalette.primary700 : PaiPalette.Semantic.textPrimary)
                        }
                        .id(entry.offset)
                    }
                }
            }
            .listStyle(.plain)
            .paiNotesListBackground()
            // Reopening a long outline at the top means finding the same heading again by hand.
            // Restoring by remembered entry rather than by scroll offset, because the outline is
            // rebuilt from the current body and an offset into the previous one lands anywhere.
            .onAppear {
                guard let last = state.lastOutlineOffset else { return }
                proxy.scrollTo(last, anchor: .center)
            }
        }
    }
}

// MARK: - In-note search

private struct NoteInNoteSearchTab: View {
    let noteBody: String
    let state: NoteToolsPanelState
    let onJumpTo: (NoteJumpTarget) -> Void

    /// What `findOccurrences` actually runs against — a note's worth of lowercasing and
    /// Character-arraying on every keystroke is exactly the per-keystroke, unbounded-by-size cost
    /// this debounce exists to avoid paying while someone is still typing.
    @State private var debouncedQuery: String
    @FocusState private var isSearchFieldFocused: Bool

    init(body: String, state: NoteToolsPanelState, onJumpTo: @escaping (NoteJumpTarget) -> Void) {
        self.noteBody = body
        self.state = state
        self.onJumpTo = onJumpTo
        _debouncedQuery = State(initialValue: state.query)
    }

    var body: some View {
        @Bindable var state = state
        let occurrences = findOccurrences(body: noteBody, query: debouncedQuery)
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                TextField("Find in this note", text: $state.query)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
                if !state.query.isEmpty {
                    Button {
                        state.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(8)
            if !state.query.isEmpty {
                Text("\(occurrences.count) \(occurrences.count == 1 ? "match" : "matches")")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            ScrollViewReader { proxy in
                List(occurrences) { occ in
                    Button {
                        state.lastSearchOffset = occ.offset
                        onJumpTo(NoteJumpTarget(characterOffset: occ.offset, query: debouncedQuery))
                    } label: {
                        Text(occ.context)
                            .lineLimit(2)
                            .foregroundStyle(
                                state.lastSearchOffset == occ.offset
                                    ? PaiPalette.primary700 : PaiPalette.Semantic.textPrimary)
                    }
                    .id(occ.offset)
                }
                .listStyle(.plain)
                .paiNotesListBackground()
                .onAppear {
                    guard let last = state.lastSearchOffset else { return }
                    proxy.scrollTo(last, anchor: .center)
                }
            }
        }
        // `.task(id:)` cancels and restarts its own sleep on every keystroke — the debounce is
        // the cancellation, not a timer this view has to manage by hand.
        .task(id: state.query) {
            guard state.query != debouncedQuery else { return }
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            debouncedQuery = state.query
        }
    }
}

// MARK: - Backlinks

private struct NoteBacklinksTab: View {
    let noteId: String
    let error: String?
    let graph: NoteLinkGraph?
    let onOpenNote: (String) -> Void

    var body: some View {
        Group {
            if let error {
                Text(error).foregroundStyle(PaiPalette.Semantic.errorText).padding()
            } else if let graph {
                List {
                    if graph.extractionSkipped {
                        Text(
                            "This note is large enough that not every link could be parsed — this list may be incomplete."
                        )
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.amber700)
                    }
                    if graph.backlinks.isEmpty {
                        Text("Nothing links here.").foregroundStyle(PaiPalette.Semantic.textMuted)
                    } else {
                        ForEach(graph.backlinks) { link in
                            Button {
                                onOpenNote(link.noteId)
                            } label: {
                                HStack {
                                    Image(systemName: "arrow.up.left").foregroundStyle(PaiPalette.Semantic.textMuted)
                                    Text(link.noteName.isEmpty ? "Untitled" : link.noteName)
                                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                                    Spacer()
                                    Text("\(link.count)")
                                        .font(PaiTypography.caption.font)
                                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .paiNotesListBackground()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Outgoing links

private struct NoteOutgoingLinksTab: View {
    let noteId: String
    let notes: NotesStore
    let toasts: ToastCenter
    let error: String?
    let graph: NoteLinkGraph?
    let containerId: String?
    let onOpenNote: (String) -> Void
    let onReload: () async -> Void

    var body: some View {
        Group {
            if let error {
                Text(error).foregroundStyle(PaiPalette.Semantic.errorText).padding()
            } else if let graph {
                let entries = graph.outgoing.filter { $0.kind == .note || $0.kind == .attachment }
                List {
                    if graph.extractionSkipped {
                        Text(
                            "This note is large enough that not every link could be parsed — this list may be incomplete."
                        )
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.amber700)
                    }
                    if entries.isEmpty {
                        Text("Nothing this note links to.").foregroundStyle(PaiPalette.Semantic.textMuted)
                    } else {
                        ForEach(Array(entries.enumerated()), id: \.offset) { _, link in
                            row(for: link)
                        }
                    }
                }
                .listStyle(.plain)
                .paiNotesListBackground()
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private func row(for link: NoteLink) -> some View {
        let label =
            link.kind == .note
            ? (link.alias ?? link.targetNoteName ?? link.pathTarget)
            : basename(link.targetAttachmentPath ?? link.pathTarget)
        HStack {
            Image(systemName: link.kind == .note ? "note.text" : "paperclip")
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            if link.kind == .note, let targetId = link.targetNoteId {
                Button {
                    onOpenNote(targetId)
                } label: {
                    Text(label).foregroundStyle(PaiPalette.Semantic.textPrimary)
                }
            } else {
                Text(label).foregroundStyle(PaiPalette.Semantic.textPrimary)
            }
            Spacer()
            if link.kind == .attachment, let containerId, let path = link.targetAttachmentPath {
                Button(role: .destructive) {
                    Task {
                        do {
                            _ = try await notes.deleteAttachment(containerId: containerId, path: path)
                            await onReload()
                        } catch {
                            toasts.show("Could not delete the attachment", kind: .error)
                        }
                    }
                } label: {
                    Image(systemName: "trash").foregroundStyle(PaiPalette.Semantic.errorText)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

// MARK: - Info

private struct NoteInfoTab: View {
    let noteId: String
    let notes: NotesStore
    let toasts: ToastCenter

    @Environment(AppEnvironment.self) private var environment
    @State private var summary = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var shareStore: NoteShareStore?
    @State private var linkPendingDelete: NoteShareKind?
    @State private var copiedKind: NoteShareKind?
    /// Whether the editable link handed out opens in the editor or in the reader.
    @State private var editLinkOpensEditing = false
    @FocusState private var isSummaryFieldFocused: Bool

    var body: some View {
        Form {
            if let note = notes.detail(for: noteId) {
                Section("Summary") {
                    TextField(
                        "What this note is about — this is what semantic search matches on", text: $summary,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    .focused($isSummaryFieldFocused)
                    // Compared against what the note already holds rather than fired on any
                    // change: this field is filled in from the note when the tab appears, and
                    // that assignment is a change like any other. Left unguarded, merely opening
                    // this tab writes the summary back — stamping the note as edited from this
                    // app, moving it to the top of a list sorted by modification time, for a
                    // value nobody touched.
                    .onChange(of: summary) { _, edited in
                        // The summary is one line of YAML frontmatter — Return must not leave a
                        // line break in it, matching what the backend's own frontmatter writer
                        // already does to whatever reaches it (see `flattenNoteSummaryLine`'s doc
                        // comment).
                        let flattened = flattenNoteSummaryLine(edited)
                        if flattened != edited {
                            summary = flattened
                            return
                        }
                        guard edited != (notes.detail(for: noteId)?.summary ?? "") else { return }
                        scheduleSave()
                    }
                }
                if note.containerId != nil, let shareStore {
                    sharingSections(shareStore)
                }
                Section {
                    LabeledContent("Created", value: formatted(note.createdAtMs))
                    LabeledContent("Last modified", value: formatted(note.updatedAtMs))
                    LabeledContent(
                        "Last change from",
                        value: note.lastWriteSource.map(NoteWriteSource.infoLabel)
                            ?? "unknown (written before this was tracked)")
                }
            } else {
                ProgressView()
            }
        }
        .task { summary = notes.detail(for: noteId)?.summary ?? "" }
        .task {
            guard shareStore == nil, let client = environment.connection?.apiClient else { return }
            let store = NoteShareStore(noteId: noteId, api: client) { [notes, noteId] shared in
                notes.markShared(id: noteId, shared: shared)
            }
            shareStore = store
            await store.load()
        }
        .confirmationDialog(
            deleteDialogTitle,
            isPresented: Binding(get: { linkPendingDelete != nil }, set: { if !$0 { linkPendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let kind = linkPendingDelete, let shareStore {
                Button("Delete link", role: .destructive) {
                    Task {
                        if await shareStore.deleteLink(kind) == nil {
                            toasts.show(shareStore.errorMessage ?? "Could not delete the link", kind: .error)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let kind = linkPendingDelete {
                Text(
                    shareStore?.deleteWarning(for: kind)
                        ?? "Anyone holding this link loses access, and its address stops working for good.")
            }
        }
    }

    // MARK: Sharing

    private var deleteDialogTitle: String {
        guard let kind = linkPendingDelete else { return "" }
        return "Delete the " + kind.label.lowercased() + "?"
    }

    /// One read-only and one editable link at most, each created, copied and deleted here, and the
    /// way into the attachment queue once either exists.
    @ViewBuilder
    private func sharingSections(_ store: NoteShareStore) -> some View {
        Section {
            ForEach(NoteShareKind.allCases, id: \.self) { kind in
                shareRow(kind, store)
            }
            if let error = store.errorMessage {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        } header: {
            Text("Sharing")
        } footer: {
            Text(
                "Anyone with a link can open this note without signing in. An editable link also lets them change the text."
            )
        }
        if store.hasAnyLink {
            Section {
                NavigationLink {
                    NoteShareQueueScreen(store: store, toasts: toasts)
                } label: {
                    LabeledContent("Attachments waiting", value: "\(store.pendingCount)")
                }
            }
        }
    }

    @ViewBuilder
    private func shareRow(_ kind: NoteShareKind, _ store: NoteShareStore) -> some View {
        if let link = store.link(kind) {
            let address = link.address(opensEditing: editLinkOpensEditing)
            VStack(alignment: .leading, spacing: 6) {
                Text(kind.label).foregroundStyle(PaiPalette.Semantic.textPrimary)
                Text(address)
                    .font(PaiTypography.monoLabel.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 12) {
                    Button {
                        UIPasteboard.general.string = address
                        copiedKind = kind
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedKind = nil
                        }
                    } label: {
                        Label(
                            copiedKind == kind ? "Copied" : "Copy",
                            systemImage: copiedKind == kind ? "checkmark" : "doc.on.doc")
                    }
                    ShareLink(item: address) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        linkPendingDelete = kind
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                .buttonStyle(.bordered)
                .labelStyle(.titleAndIcon)
                .font(PaiTypography.caption.font)
                if link.editingUrl != nil {
                    Toggle("Opens in the editor", isOn: $editLinkOpensEditing)
                        .font(PaiTypography.caption.font)
                }
            }
        } else {
            Button {
                Task {
                    if await store.createLink(kind) == nil {
                        toasts.show(store.errorMessage ?? "Could not create the link", kind: .error)
                    }
                }
            } label: {
                Label("Create \(kind.label.lowercased())", systemImage: "link.badge.plus")
            }
            .disabled(store.isBusy)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled else { return }
            if !(await notes.updateSummary(id: noteId, summary: summary)) {
                toasts.show(notes.loadError ?? "Could not save the summary", kind: .error)
            }
        }
    }

    private func formatted(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return Date(timeIntervalSince1970: Double(ms) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Revision history

private struct NoteRevisionsTab: View {
    let noteId: String
    let notes: NotesStore
    let toasts: ToastCenter

    @State private var openId: String?
    @State private var detail: NoteRevisionDetail?
    @State private var restoringId: String?

    var body: some View {
        List {
            if let error = notes.revisionErrors[noteId] {
                Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
            } else if let revisions = notes.revisions[noteId] {
                if revisions.isEmpty {
                    Text("No previous versions yet.").foregroundStyle(PaiPalette.Semantic.textMuted)
                } else {
                    ForEach(revisions) { revision in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { openId == revision.id },
                                set: { expanded in
                                    openId = expanded ? revision.id : nil
                                    if expanded {
                                        Task {
                                            detail = try? await notes.getRevision(
                                                noteId: noteId, revisionId: revision.id)
                                        }
                                    }
                                }
                            )
                        ) {
                            if openId == revision.id {
                                if let detail {
                                    Text(detail.body)
                                        .font(.system(.footnote, design: .monospaced))
                                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                                        .lineLimit(12)
                                } else {
                                    ProgressView()
                                }
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        Date(timeIntervalSince1970: Double(revision.createdAtMs) / 1000).formatted(
                                            date: .abbreviated, time: .shortened)
                                    )
                                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                                    Text(
                                        "\(NoteWriteSource.historyLabel(revision.source)) · \(formatSize(revision.sizeBytes))"
                                    )
                                    .font(PaiTypography.caption.font)
                                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                                }
                                Spacer()
                                Button {
                                    Task {
                                        restoringId = revision.id
                                        let ok = await notes.restoreRevision(noteId: noteId, revisionId: revision.id)
                                        restoringId = nil
                                        toasts.show(
                                            ok
                                                ? "Restored — the current text now matches this version"
                                                : (notes.loadError ?? "Could not restore this version"),
                                            kind: ok ? .info : .error)
                                    }
                                } label: {
                                    if restoringId == revision.id {
                                        ProgressView()
                                    } else {
                                        Image(systemName: "arrow.uturn.backward")
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(restoringId != nil)
                            }
                        }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .listStyle(.plain)
        .paiNotesListBackground()
        .task { await notes.loadRevisions(id: noteId) }
    }

    private func formatSize(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}
