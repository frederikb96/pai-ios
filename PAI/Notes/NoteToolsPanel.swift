import PAIKit
import SwiftUI

/// The iOS-native shape of the web's right-hand panel (`RightPanel.tsx`): outline, in-note
/// search, backlinks, outgoing links, note info and revision history — six tabs behind one icon
/// row, reached from `NoteActionsSheet` rather than docked beside an open editor, since a phone
/// has no room for both at once. Loads a snapshot on appearance rather than staying live, for the
/// same reason the web gives: cutting and pasting a link around should not disturb this list
/// while a note is being edited elsewhere.
struct NoteToolsPanel: View {
    let noteId: String
    let onOpenNote: (String) -> Void
    /// A Character offset into the note body the editor should put the caret at.
    let onJumpTo: (Int) -> Void

    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var tab: Tab = .outline
    @State private var isLoading = false

    private enum Tab: CaseIterable, Hashable {
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

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            content
        }
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
                ForEach(Tab.allCases, id: \.self) { candidate in
                    Button {
                        tab = candidate
                    } label: {
                        Image(systemName: candidate.icon)
                            .frame(width: 36, height: 32)
                    }
                    .foregroundStyle(tab == candidate ? PaiPalette.primary700 : PaiPalette.Semantic.textMuted)
                    .background(
                        tab == candidate ? PaiPalette.primary50 : Color.clear, in: RoundedRectangle(cornerRadius: 8)
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
        switch tab {
        case .outline:
            // The body as it stands on screen, not the last one saved. They differ for as long as
            // the autosave debounce runs, and an outline that is one paragraph behind sends every
            // jump below it to the wrong place.
            NoteOutlineTab(body: notes.body(for: noteId) ?? "", onJumpTo: onJumpTo)
        case .search:
            NoteInNoteSearchTab(body: notes.body(for: noteId) ?? "", onJumpTo: onJumpTo)
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
    }
}

// MARK: - Outline

private struct NoteOutlineTab: View {
    let noteBody: String
    let onJumpTo: (Int) -> Void

    init(body: String, onJumpTo: @escaping (Int) -> Void) {
        self.noteBody = body
        self.onJumpTo = onJumpTo
    }

    var body: some View {
        let entries = parseOutline(noteBody)
        List {
            if entries.isEmpty {
                Text("No headings in this note.").foregroundStyle(PaiPalette.Semantic.textMuted)
            } else {
                ForEach(entries) { entry in
                    Button {
                        onJumpTo(entry.offset)
                    } label: {
                        Text(entry.text)
                            .padding(.leading, CGFloat(entry.level - 1) * 12)
                            .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - In-note search

private struct NoteInNoteSearchTab: View {
    let noteBody: String
    let onJumpTo: (Int) -> Void
    @State private var query = ""

    init(body: String, onJumpTo: @escaping (Int) -> Void) {
        self.noteBody = body
        self.onJumpTo = onJumpTo
    }

    var body: some View {
        let occurrences = findOccurrences(body: noteBody, query: query)
        VStack(spacing: 0) {
            TextField("Find in this note", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            if !query.isEmpty {
                Text("\(occurrences.count) \(occurrences.count == 1 ? "match" : "matches")")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }
            List(occurrences) { occ in
                Button {
                    onJumpTo(occ.offset)
                } label: {
                    Text(occ.context)
                        .lineLimit(2)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                }
            }
            .listStyle(.plain)
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

    @State private var summary = ""
    @State private var saveTask: Task<Void, Never>?

    private static let sourceLabel: [String: String] = [
        "ui": "this app", "disk": "the synced folder on disk", "mcp": "an MCP tool call",
        "rename": "a link rewrite from renaming something else", "restore": "restoring a previous version",
    ]

    var body: some View {
        Form {
            if let note = notes.detail(for: noteId) {
                Section("Summary") {
                    TextField(
                        "What this note is about — this is what semantic search matches on", text: $summary,
                        axis: .vertical
                    )
                    .lineLimit(2...5)
                    // Compared against what the note already holds rather than fired on any
                    // change: this field is filled in from the note when the tab appears, and
                    // that assignment is a change like any other. Left unguarded, merely opening
                    // this tab writes the summary back — stamping the note as edited from this
                    // app, moving it to the top of a list sorted by modification time, for a
                    // value nobody touched.
                    .onChange(of: summary) { _, edited in
                        guard edited != (notes.detail(for: noteId)?.summary ?? "") else { return }
                        scheduleSave()
                    }
                }
                Section {
                    LabeledContent("Created", value: formatted(note.createdAtMs))
                    LabeledContent("Last modified", value: formatted(note.updatedAtMs))
                    LabeledContent(
                        "Last change from",
                        value: note.lastWriteSource.flatMap { Self.sourceLabel[$0] }
                            ?? "unknown (written before this was tracked)")
                }
            } else {
                ProgressView()
            }
        }
        .task { summary = notes.detail(for: noteId)?.summary ?? "" }
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
                                    Text("\(revision.source) · \(formatSize(revision.sizeBytes))")
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
        .task { await notes.loadRevisions(id: noteId) }
    }

    private func formatSize(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}
