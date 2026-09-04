import PAIKit
import SwiftUI

/// One spec's whole timeline as a Tines-style flowchart — mirrors the web's `ArcApp`/
/// `ArcFlowSegment`/`ArcBlockCard`: a marker bar per segment, then that segment's own blocks laid
/// out left to right in one horizontally-scrolling row (real parallelism, drawn side by side
/// rather than stacked), connected to the marker above and below by short fixed vertical lines
/// meeting the row's own dashed top border — the horizontal trunk. Reached from a session's
/// "Spec" action or from the Apps → Arc spec list, never from a shortcut, so it carries no
/// deep-link concern of its own.
struct ArcSpecView: View {
    let specUuid: String
    /// The conversation this spec was opened from, if the view was reached from one that is
    /// currently open — enables the live SSE-driven refresh AND is the preferred candidate for
    /// `ArcSubagentLookup.resolveBoundSessionId` (the common case: opened from the session that
    /// is itself bound to the spec). `nil` from the session LIST swipe or the Apps spec list,
    /// where nothing has an open transcript stream to prefer. Either way the poll fallback below
    /// keeps the screen from ever going stale for long, and the badge lookup falls back to
    /// scanning every other loaded session.
    let sessionID: String?

    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessionList
    @Environment(ToastCenter.self) private var toasts
    @State private var store: ArcSpecStore?
    @State private var detailTarget: ArcDetailTarget?

    /// The vertical timeline's own scroll anchor, and each segment's own horizontal row anchor —
    /// both `@State` on this view, which `NavigationStack` keeps alive (never torn down) while a
    /// badge tap's pushed subagent transcript sits on top of it, so both survive a swipe back
    /// with no store or persistence layer needed. Keyed the same way the web keys its own
    /// `scrollPositions` (segment index), since a segment has no id of its own.
    @State private var topSegmentID: Int?
    @State private var rowScrollAnchors: [Int: ArcCardID] = [:]

    /// How often this screen refreshes on its own when no live SSE signal is reaching it —
    /// mirrors `SessionDetailView`'s own usage-poll interval, the closest existing precedent for
    /// "a number on this screen changes from the outside and there is no push for it".
    private static let pollInterval: Duration = .seconds(15)

    var body: some View {
        Group {
            if let store {
                content(store: store)
            } else {
                ProgressView()
            }
        }
        .paiScreenBackground()
        .navigationTitle(store?.name ?? "Spec")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("arc-spec-view")
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = ArcSpecStore(specUuid: specUuid, api: client)
            store = newStore
            await newStore.load()
        }
        .task(id: sessionID) {
            // Only meaningful with a session to listen on — see `sessionID`'s doc comment.
            guard let sessionID, let connection = environment.connection else { return }
            while !Task.isCancelled {
                store?.applyLiveSignal(connection.transcript.liveArc[sessionID])
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                await store?.refreshQuietly()
            }
        }
        .sheet(item: $detailTarget) { target in
            switch target {
            case .block(let block):
                ArcBlockDetailSheet(block: block)
            case .unassigned(let rows):
                ArcUnassignedDetailSheet(rows: rows)
            }
        }
    }

    @ViewBuilder
    private func content(store: ArcSpecStore) -> some View {
        if let message = store.errorMessage, store.timeline == nil {
            centeredMessage(message, systemImage: "exclamationmark.triangle")
        } else if let timeline = store.timeline {
            VStack(alignment: .leading, spacing: 0) {
                ArcLegendView()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let overview = store.overview, !overview.isEmpty {
                            Text(overview)
                                .font(PaiTypography.caption.font)
                                .foregroundStyle(PaiPalette.Semantic.textMuted)
                                .padding(.horizontal, 16)
                                .padding(.top, 8)
                                .padding(.bottom, 4)
                        }
                        ForEach(timeline.segments) { segment in
                            ArcFlowSegmentView(
                                segment: segment,
                                onOpenBlock: { detailTarget = .block($0) },
                                onOpenBadge: { openBadge(for: $0, store: store) },
                                onOpenUnassigned: { detailTarget = .unassigned($0) },
                                rowScrollBinding: rowScrollBinding(for: segment.index)
                            )
                            .id(segment.index)
                        }
                        if timeline.segments.allSatisfy({ $0.blocks.isEmpty && $0.looseRows.isEmpty }) {
                            Text("This spec has no rows yet.")
                                .font(PaiTypography.body.font)
                                .foregroundStyle(PaiPalette.Semantic.textMuted)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 48)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollPosition(id: $topSegmentID)
                .refreshable { await store.load() }
            }
        } else if store.isLoading {
            centeredMessage(nil, systemImage: nil)
        }
    }

    private func rowScrollBinding(for segmentIndex: Int) -> Binding<ArcCardID?> {
        Binding(
            get: { rowScrollAnchors[segmentIndex] },
            set: { rowScrollAnchors[segmentIndex] = $0 }
        )
    }

    /// A block card's icon tile — opens its subagent's transcript when there is a named agent to
    /// look up, falling back to the detail sheet the same way the body of the card does
    /// (mirroring `ArcApp.tsx`'s own `onBadgeClick` wiring). Mirrors `ArcApp.tsx`'s `openSubagent`
    /// exactly: resolve which loaded session the spec is bound to, then walk that session's own
    /// subagents by name.
    private func openBadge(for block: ArcTimelineBlock, store: ArcSpecStore) {
        guard let name = block.leader?.g?.name else {
            detailTarget = .block(block)
            return
        }
        guard let client = environment.connection?.apiClient else { return }
        guard
            let boundSessionId = ArcSubagentLookup.resolveBoundSessionId(
                specSessions: store.boundSessions, activeSessionId: sessionID, sessions: sessionList.syncedSessions)
        else {
            toasts.show("Cannot find the bound session to look up its subagents", kind: .info)
            return
        }
        Task {
            do {
                let target = try await ArcSubagentLookup.findBoundSubagent(agentName: name) { cursor in
                    try await client.getSessions(
                        since: nil, limit: nil, cursor: cursor, agent: nil, kind: .subagent, parent: boundSessionId,
                        q: nil)
                }
                guard let target else {
                    toasts.show("\"\(name)\" has not reported in yet", kind: .info)
                    return
                }
                environment.router.push(.session(id: target.id))
            } catch {
                toasts.show((error as? PaiError)?.userMessage ?? "Could not look up that subagent", kind: .error)
            }
        }
    }

    private func centeredMessage(_ text: String?, systemImage: String?) -> some View {
        VStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            } else {
                ProgressView()
            }
            if let text {
                Text(text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// The `.sheet(item:)` target for the block detail sheet — a real block, or the synthetic
/// bundle of one segment's own unassigned rows. Mirrors `ArcDetailSheet.tsx`'s own
/// `ArcDetailTarget` union.
private enum ArcDetailTarget: Identifiable {
    case block(ArcTimelineBlock)
    case unassigned([ArcRow])

    var id: String {
        switch self {
        case .block(let block): return "block-\(block.id)"
        case .unassigned: return "unassigned"
        }
    }
}

/// A horizontal row's own scroll-restoration anchor — a real block by id, or the segment's
/// synthetic unassigned card. Distinct from `ArcDetailTarget`: this only ever needs identity for
/// `.scrollPosition(id:)`, never the row data itself.
enum ArcCardID: Hashable {
    case block(Int)
    case unassigned
}

// MARK: - Segment

/// One segment of the flow: the marker bar that opened it (if any — the first segment has
/// none), a fixed connector down into its own horizontally-scrolling row of blocks, then a
/// connector down to the next marker. Mirrors `ArcFlowSegment.tsx`.
private struct ArcFlowSegmentView: View {
    let segment: ArcTimelineSegment
    let onOpenBlock: (ArcTimelineBlock) -> Void
    let onOpenBadge: (ArcTimelineBlock) -> Void
    let onOpenUnassigned: ([ArcRow]) -> Void
    let rowScrollBinding: Binding<ArcCardID?>

    private var hasRow: Bool { !segment.blocks.isEmpty || !segment.looseRows.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let marker = segment.marker {
                ArcMarkerBar(marker: marker)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
            }
            if hasRow {
                ArcConnectorStub()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, segment.marker == nil ? 12 : 6)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(segment.blocks) { block in
                            VStack(spacing: 0) {
                                ArcConnectorStub()
                                ArcFlowBlockCard(
                                    block: block, onOpenDetail: { onOpenBlock(block) },
                                    onOpenBadge: { onOpenBadge(block) })
                            }
                            .id(ArcCardID.block(block.id))
                        }
                        if !segment.looseRows.isEmpty {
                            VStack(spacing: 0) {
                                ArcConnectorStub()
                                ArcUnassignedFlowCard(rows: segment.looseRows) {
                                    onOpenUnassigned(segment.looseRows)
                                }
                            }
                            .id(ArcCardID.unassigned)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .overlay(alignment: .top) {
                        ArcDashedTrunk().padding(.horizontal, 16)
                    }
                }
                .scrollPosition(id: rowScrollBinding)

                ArcConnectorStub()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// A short fixed vertical line — the connector between a marker and its row, and between a
/// card's own top and the row's dashed trunk. Mirrors `ArcFlowSegment.tsx`'s `CONNECTOR`.
private struct ArcConnectorStub: View {
    var body: some View {
        Rectangle()
            .fill(PaiPalette.Semantic.borderStrong)
            .frame(width: 1, height: 10)
    }
}

/// The row's own dashed top border — the horizontal trunk every card's connector stub branches
/// from. Lives INSIDE the same horizontally-scrolling container as the cards (an `.overlay` on
/// the same `HStack`), so it scrolls together with them for free rather than as a second element
/// whose `scrollLeft` would need mirroring from outside — the same reasoning `ArcFlowSegment.tsx`
/// documents on itself.
private struct ArcDashedTrunk: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: geometry.size.width, y: 0))
            }
            .stroke(PaiPalette.Semantic.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .frame(height: 1)
    }
}

// MARK: - Marker bar

/// The horizontal bar between two segments — its `i` is why the run waits here, its `v` how it
/// knows it may pass. See the design report's §1 for the picture this renders literally.
///
/// A marker's own status carries only two shapes (`nil`, still open, or `"D"`, passed — nothing
/// else is legal) — rendered distinguishably by icon, colour AND word together, matching
/// `ArcBadgeView`'s own "colour plus label, never colour alone" rule, so a passed marker never
/// reads the same as one the run has not reached yet.
private struct ArcMarkerBar: View {
    let marker: ArcRow

    private var passed: Bool { marker.s == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Rectangle().fill(PaiPalette.Semantic.borderStrong).frame(height: 1)
                if passed {
                    Label("Passed", systemImage: "checkmark.seal.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(PaiPalette.green500)
                } else {
                    Image(systemName: "flag.checkered")
                        .font(.caption)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                Rectangle().fill(PaiPalette.Semantic.borderStrong).frame(height: 1)
            }
            if let text = marker.i, !text.isEmpty {
                Text(text)
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
            }
            if let check = marker.v, !check.isEmpty {
                Text(check)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
    }
}

// MARK: - Flow block card

/// One flow card — a coloured icon tile at the left edge (the state, legible without opening the
/// card, from `ArcStateStyle`'s single shared table), a small type label above the title (who is
/// doing it: `type · model-code · name`, or `Kai` for the main session's own work), and the
/// leader's own plain-language sentence as the title. Mirrors `ArcBlockCard.tsx`.
///
/// The icon tile and the title/body area are two SIBLING buttons, not one nested inside the
/// other, matching the web's own reasoning (an accessible-name conflict, and a tile that must
/// stay tappable on its own for the subagent lookup regardless of where the rest of the card
/// leads). The tile opens the block's subagent transcript (falling back to the detail sheet when
/// there is no agent to look up); the rest opens the detail sheet.
private struct ArcFlowBlockCard: View {
    let block: ArcTimelineBlock
    let onOpenDetail: () -> Void
    let onOpenBadge: () -> Void

    private var meta: ArcStateMeta { ArcStateStyle.meta(for: block.badge) }

    /// `{done}/{total} rows done`, always — a leader-only block (`total == 0`) reads as `0/0
    /// rows done` rather than a special-cased string, so it renders exactly like any other block
    /// rather than looking like a distinct kind of card.
    private var rowCountText: String {
        var text = "\(block.done)/\(block.total) rows done"
        if block.cancelled > 0 { text += " · \(block.cancelled) cancelled" }
        return text
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpenBadge) {
                Image(systemName: meta.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
            }
            .frame(maxHeight: .infinity)
            .background(meta.tileColor)
            .accessibilityLabel(
                block.agentLabel.map { "\($0) — \(meta.label)" } ?? "Block state: \(meta.label)")

            Button(action: onOpenDetail) {
                VStack(alignment: .leading, spacing: 2) {
                    if let label = block.agentLabel {
                        Text(label)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                            .lineLimit(1)
                    }
                    Text(block.leader?.i ?? "Block \(block.id)")
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .strikethrough(block.badge == .cancelled)
                    Text(rowCountText)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
        .background(meta.cardBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(meta.cardBorderColor, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .opacity(block.badge == .cancelled ? 0.6 : 1)
        .accessibilityIdentifier("arc-block-\(block.id)")
    }
}

/// One of the five states a block's agent can be in, rendered as a small labelled dot — matches
/// `SessionStateIndicator`'s own "colour plus label, never colour alone" rule. Reads its colour
/// and icon from `ArcStateStyle`'s single shared table, the same one the flow card's icon tile
/// and `ArcLegendView` read, so a state's appearance is never chosen twice.
struct ArcBadgeView: View {
    let state: ArcBadgeState

    var body: some View {
        let meta = ArcStateStyle.meta(for: state)
        Label(meta.label, systemImage: meta.systemImage)
            .labelStyle(.titleAndIcon)
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(meta.tileColor)
            .accessibilityLabel("Agent status: \(meta.label)")
    }
}

// MARK: - Unassigned card

/// The synthetic card for a segment's own loose rows (`k == .regular`, `b == nil`) — a UI-only
/// bundle, never written to the spec itself, that keeps a segment with a handful of unassigned
/// rows from growing an unbounded tail of one-off cards beside its real blocks. Sits at the
/// right of its segment's row; tapping lists the rows it bundles in `ArcUnassignedDetailSheet`.
/// Mirrors `ArcUnassignedCard.tsx`.
private struct ArcUnassignedFlowCard: View {
    let rows: [ArcRow]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(PaiPalette.surface400)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Unassigned rows")
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                    Text("\(rows.count) \(rows.count == 1 ? "row" : "rows")")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .frame(minWidth: 200, maxWidth: 280, alignment: .leading)
        .background(PaiPalette.Semantic.panelBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(PaiPalette.Semantic.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("arc-unassigned")
    }
}

// MARK: - Legend

/// The five states in one row, colour swatch plus word — always on screen under the header
/// rather than a tap away, since the flow card's whole "colour alone encodes state" design only
/// holds if the legend spelling out what each colour means never has to be recalled from memory.
/// Wrapped in its own horizontal scroll rather than truncating on a narrow phone. Mirrors
/// `ArcLegend.tsx`, reading the same `ArcStateStyle` table the flow card's icon tile does.
private struct ArcLegendView: View {
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(ArcStateStyle.allStates, id: \.self) { state in
                    let meta = ArcStateStyle.meta(for: state)
                    HStack(spacing: 5) {
                        Circle().fill(meta.tileColor).frame(width: 8, height: 8)
                        Text(meta.label)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
            }
        }
        .accessibilityIdentifier("arc-legend")
    }
}
