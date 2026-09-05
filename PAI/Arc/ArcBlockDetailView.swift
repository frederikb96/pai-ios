import PAIKit
import SwiftUI

/// A block's leader plus every row it owns — a pushed page reached by tapping a block card in
/// `ArcSpecView`, replacing what used to be a `.sheet`: a report chip tapped from in here used to
/// push onto the app's navigation stack while the sheet stayed on top of it, so the report landed
/// full-screen behind a sheet that still said Close. Sheets and pushes do not compose. This is an
/// ordinary page on the same stack instead, so a report opens in front and Back returns here, at
/// the scroll position it was left at (`topRowID`, restored the same identity-anchored way
/// `ArcSpecView`'s own horizontal rows already are).
struct ArcBlockDetailView: View {
    let block: ArcTimelineBlock
    let specUuid: String
    @Binding var topRowID: Int?

    var body: some View {
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
                    // Freddy, from a screenshot: a leader's own verification and notes must both
                    // be reachable, truncated up front and expandable on demand — nothing a row
                    // carries may be unreachable.
                    if let check = leader.v, !check.isEmpty {
                        ArcExpandableVerification(text: check)
                    }
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
                        .id(row.id)
                }
            }
        }
        .scrollPosition(id: $topRowID)
        .navigationTitle("Block \(block.id)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func agentSummary(_ agent: ArcLeaderAgent) -> String {
        agent.name ?? agent.model ?? agent.type ?? "Agent"
    }
}

/// One segment's own unassigned rows (`k == .regular`, `b == nil`) — the page the flow view's
/// synthetic "Unassigned rows" card opens, listing every row it bundles the same way a block's
/// own rows are listed. UI-only: nothing here writes to the spec.
struct ArcUnassignedDetailView: View {
    let rows: [ArcRow]
    let specUuid: String
    @Binding var topRowID: Int?

    var body: some View {
        List {
            Section("Rows") {
                ForEach(rows) { row in
                    ArcRowSummaryRow(row: row, specUuid: specUuid)
                        .id(row.id)
                }
            }
        }
        .scrollPosition(id: $topRowID)
        .navigationTitle("Unassigned rows")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// One row inside a block's page — status glyph, goal text, and (expanded in place, never a
/// further navigation) its own reports, verification and notes. Distinguishes all five statuses
/// rather than collapsing to done/not-done: a cancelled row looks nothing like a pending one,
/// even though neither is "done".
///
/// Everything the row carries lives right here rather than behind a further tap-through — the
/// row IS the detail, the same way the block page shows the leader's own verification and notes
/// inline in its header rather than behind a second screen.
struct ArcRowSummaryRow: View {
    let row: ArcRow
    let specUuid: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(row.i ?? "Row \(row.id)")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .strikethrough(row.s == .done || row.s == .cancelled)
            }
            if let check = row.v, !check.isEmpty {
                ArcExpandableVerification(text: check)
                    .padding(.leading, 24)
            }
            if let preview = row.notesMarkdown {
                ArcNotesPreview(markdown: preview)
                    .padding(.leading, 24)
            }
            if let reports = row.r, !reports.isEmpty {
                ArcReportChipRow(specUuid: specUuid, reportUuids: reports)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 2)
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
/// identical reasoning on the web. Tapping pushes the report's own full page onto the same
/// navigation stack this page is already on — no dismissal to order around, since neither this
/// nor the report is a sheet any more.
private struct ArcReportChip: View {
    let specUuid: String
    let reportUuid: String

    @Environment(AppEnvironment.self) private var environment
    @State private var name: String?

    var body: some View {
        Button {
            environment.router.push(.arcReport(specUuid: specUuid, reportUuid: reportUuid))
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

/// A short plain-text field (a row or leader's own verification/check) — clamped to two lines by
/// default and expanded IN PLACE to a scrollable box on tap, never routed through the full-screen
/// markdown viewer `ArcNotesPreview` uses: verification is short plain text, so an inline expand
/// is the whole detail a tap needs to reach, unlike notes, which are markdown and routinely run
/// to thousands of characters.
struct ArcExpandableVerification: View {
    let text: String

    @State private var isExpanded = false

    private static let collapsedLineLimit = 2
    private static let expandedMaxHeight: CGFloat = 160

    var body: some View {
        Group {
            if isExpanded {
                ScrollView {
                    Text(text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: Self.expandedMaxHeight)
            } else {
                Text(text)
                    .lineLimit(Self.collapsedLineLimit)
                    .truncationMode(.tail)
            }
        }
        .font(PaiTypography.caption.font)
        .foregroundStyle(PaiPalette.Semantic.textFaint)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A plain tap gesture rather than a `Button` — this wraps a `ScrollView` once expanded,
        // and a scroll view's own drag would fight a `Button`'s tap recognizer for the gesture.
        // SwiftUI (like UIKit underneath it) already resolves a tap-vs-drag ambiguity correctly on
        // its own; a `Button` wrapping a scroll view is the one shape that reintroduces it.
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("arc-verification")
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
