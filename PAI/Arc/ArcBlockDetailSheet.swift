import PAIKit
import SwiftUI

/// A block's leader plus every row it owns — reached by tapping a block card in `ArcSpecView`.
struct ArcBlockDetailSheet: View {
    let block: ArcTimelineBlock
    let specUuid: String

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
                            // The leader's own reports — `block.rows` deliberately excludes the
                            // leader itself (see `ArcTimeline.swift`), so this is the one place
                            // its `r` field surfaces, mirroring `ArcDetailSheet.tsx`'s identical
                            // header-row treatment.
                            if let reports = leader.r, !reports.isEmpty {
                                ArcReportChipRow(specUuid: specUuid, reportUuids: reports)
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
                        ArcRowSummaryRow(row: row, specUuid: specUuid)
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
        agent.name ?? agent.model ?? agent.type ?? "Agent"
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

/// One segment's own unassigned rows (`k == .regular`, `b == nil`) — the sheet the flow view's
/// synthetic "Unassigned rows" card opens, listing every row it bundles the same way a block's
/// own rows are listed. UI-only: nothing here writes to the spec.
struct ArcUnassignedDetailSheet: View {
    let rows: [ArcRow]
    let specUuid: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Rows") {
                    ForEach(rows) { row in
                        ArcRowSummaryRow(row: row, specUuid: specUuid)
                    }
                }
            }
            .navigationTitle("Unassigned rows")
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

/// One row inside a block detail sheet — status glyph, goal text, tap opens the row's own detail.
/// Distinguishes all five statuses rather than collapsing to done/not-done: a cancelled row
/// looks nothing like a pending one, even though neither is "done".
struct ArcRowSummaryRow: View {
    let row: ArcRow
    let specUuid: String

    @State private var isPresentingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isPresentingDetail = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(row.i ?? "Row \(row.id)")
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        .strikethrough(row.s == .done || row.s == .cancelled)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
            if let reports = row.r, !reports.isEmpty {
                ArcReportChipRow(specUuid: specUuid, reportUuids: reports)
                    .padding(.leading, 24)
            }
        }
        .sheet(isPresented: $isPresentingDetail) {
            ArcRowDetailSheet(title: "Row", row: row)
        }
    }

    private var statusIcon: String {
        switch row.s {
        case .pending, nil, .unrecognized: return "circle"
        case .inProgress: return "gearshape.2.fill"
        case .verify: return "checkmark.seal"
        case .done: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch row.s {
        case .pending, nil, .unrecognized: return PaiPalette.Semantic.textFaint
        case .inProgress: return PaiPalette.Semantic.accentText
        case .verify: return PaiPalette.Semantic.warningText
        case .done: return PaiPalette.green500
        case .cancelled: return PaiPalette.Semantic.textFaint
        }
    }
}

/// A row of report chips — one per uuid in a row or a block leader's own `r` field, wrapping
/// onto a new line rather than scrolling, since a row rarely carries more than one or two.
struct ArcReportChipRow: View {
    let specUuid: String
    let reportUuids: [String]

    var body: some View {
        // `HStack` rather than a wrapping layout: matches every other chip row in this app
        // (`ArcLegendView`, the leader's own agent/badge row above), and a row's `r` field is
        // never large enough in practice to need one.
        HStack(spacing: 6) {
            ForEach(reportUuids, id: \.self) { reportUuid in
                ArcReportChip(specUuid: specUuid, reportUuid: reportUuid)
            }
        }
    }
}

/// One report a row or a block leader's `r` field names — the uuid alone tells nothing readable,
/// so the name is fetched lazily on mount purely to label the chip, mirroring `ArcReportLink`'s
/// identical reasoning on the web. Tapping pushes the report's own full-page screen onto the app
/// navigation stack FIRST, then dismisses whichever sheet the chip is inside — the block or
/// unassigned detail sheet, reached via `@Environment(\.dismiss)`, which resolves to the nearest
/// enclosing presentation regardless of how deep this chip sits inside that sheet's own `List`.
/// Push-before-dismiss is the order `CreateSessionView` documents: a push made while a sheet is
/// mid-dismissal is dropped silently.
private struct ArcReportChip: View {
    let specUuid: String
    let reportUuid: String

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var name: String?

    var body: some View {
        Button {
            environment.router.push(.arcReport(specUuid: specUuid, reportUuid: reportUuid))
            dismiss()
        } label: {
            Label(name ?? "Report", systemImage: "doc.text")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(PaiPalette.Semantic.panelBackground, in: Capsule())
        }
        .buttonStyle(.plain)
        .task {
            guard let client = environment.connection?.apiClient else { return }
            // A report deleted after the row was written, or a transient failure — the chip
            // still works (the report screen has its own error state), it just can't show a
            // name yet, matching `ArcReportLink`'s identical fallback on the web.
            name = try? await client.getArcReport(uuid: reportUuid).name
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

/// The full, scrollable render a notes preview taps into — and, with `title: "Overview"`, the
/// sheet `ArcSpecView`'s own header button opens for the spec's overview. One renderer for both,
/// since neither is anything but rendered markdown behind a "Close" button.
struct ArcMarkdownFullScreenView: View {
    let markdown: String
    var title: String = "Notes"

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                MarkdownContentView(blocks: MarkdownParser.parse(markdown))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
