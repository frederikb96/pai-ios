import PAIKit
import SwiftUI

/// A block's leader plus every row it owns — reached by tapping a block card in `ArcSpecView`.
struct ArcBlockDetailSheet: View {
    let block: ArcTimelineBlock

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let leader = block.leader {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(leader.i ?? "Block \(block.id)")
                                .font(PaiTypography.bodyEmphasized.font)
                            HStack {
                                ArcBadgeView(state: block.badge)
                                Spacer()
                                if let agent = leader.g {
                                    Text(agentSummary(agent))
                                        .font(PaiTypography.monoLabel.font)
                                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                        if let preview = leader.notesMarkdown {
                            ArcNotesPreview(markdown: preview)
                        }
                    }
                }
                Section("Rows") {
                    if block.rows.isEmpty {
                        // Per S23, a leader-only block has no member rows to show, and none ever
                        // coming — distinct from a block still waiting on work.
                        Text("Leader only — no other rows in this block.")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    ForEach(block.rows) { row in
                        ArcRowSummaryRow(row: row)
                    }
                }
            }
            .navigationTitle("Block \(block.id)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func agentSummary(_ agent: ArcLeaderAgent) -> String {
        [agent.name, agent.model, agent.type].compactMap { $0 }.first.map { "\($0)" }
            ?? agent.type
    }
}

/// One row's own detail — its goal, its acceptance check (on a marker) and its notes, with a
/// full-screen markdown render a tap away.
struct ArcRowDetailSheet: View {
    let title: String
    let row: ArcRow

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(row.i ?? title)
                        .font(PaiTypography.bodyEmphasized.font)
                    if let check = row.v, !check.isEmpty {
                        LabeledContent("Check") { Text(check) }
                            .font(PaiTypography.caption.font)
                    }
                }
                if let preview = row.notesMarkdown {
                    Section("Notes") {
                        ArcNotesPreview(markdown: preview)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// One row inside a block detail sheet — status dot, goal text, tap opens the row's own detail.
private struct ArcRowSummaryRow: View {
    let row: ArcRow

    @State private var isPresentingDetail = false

    var body: some View {
        Button {
            isPresentingDetail = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: row.s == .done ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.s == .done ? PaiPalette.green500 : PaiPalette.Semantic.textFaint)
                Text(row.i ?? "Row \(row.id)")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(2)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresentingDetail) {
            ArcRowDetailSheet(title: "Row", row: row)
        }
    }
}

/// A markdown preview truncated to a few lines, with a tap opening the same content full-screen
/// and scrollable — matches the design report's §10: "a preview in the block sheet, a tap opens
/// a full-screen scrollable render." Reuses the transcript's own `MarkdownContentView` rather
/// than the notes editor's separate renderer, per the same report: notes here are read-only
/// context, not a document being edited.
struct ArcNotesPreview: View {
    let markdown: String

    @State private var isPresentingFullScreen = false

    private static let previewLineLimit = 6

    var body: some View {
        Button {
            isPresentingFullScreen = true
        } label: {
            MarkdownContentView(blocks: MarkdownParser.parse(markdown))
                .lineLimit(Self.previewLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresentingFullScreen) {
            ArcMarkdownFullScreenView(markdown: markdown)
        }
    }
}

/// The full, scrollable render a notes preview taps into.
struct ArcMarkdownFullScreenView: View {
    let markdown: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownContentView(blocks: MarkdownParser.parse(markdown))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
