import PAIKit
import SwiftUI

/// One spec's whole timeline — segments top to bottom, a marker bar between each, block cards
/// inside a segment, and any loose row shown plainly alongside them. Reached from a session's
/// "Spec" action (`ArcSpecEntryPoint`), never from a shortcut, so it carries no deep-link concern
/// of its own.
struct ArcSpecView: View {
    let specUuid: String
    /// The conversation this spec was opened from, if the view was reached from one that is
    /// currently open — enables the live SSE-driven refresh; `nil` from the session LIST swipe,
    /// where nothing has an open transcript stream to listen on. Either way the poll fallback
    /// below keeps the screen from ever going stale for long.
    let sessionID: String?

    @Environment(AppEnvironment.self) private var environment
    @State private var store: ArcSpecStore?
    @State private var detailTarget: ArcTimelineBlock?
    @State private var looseRowTarget: ArcRow?

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
        .sheet(item: $detailTarget) { block in
            ArcBlockDetailSheet(block: block)
        }
        .sheet(item: $looseRowTarget) { row in
            ArcRowDetailSheet(title: "Row", row: row)
        }
    }

    @ViewBuilder
    private func content(store: ArcSpecStore) -> some View {
        if let message = store.errorMessage, store.timeline == nil {
            centeredMessage(message, systemImage: "exclamationmark.triangle")
        } else if let timeline = store.timeline {
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
                        segmentView(segment)
                    }
                }
                .padding(.bottom, 24)
            }
            .refreshable { await store.load() }
        } else if store.isLoading {
            centeredMessage(nil, systemImage: nil)
        }
    }

    // MARK: - Segment

    private func segmentView(_ segment: ArcTimelineSegment) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(segment.blocks) { block in
                ArcBlockCard(block: block) { detailTarget = block }
                    .padding(.horizontal, 16)
            }
            ForEach(segment.looseRows) { row in
                ArcLooseRowView(row: row) { looseRowTarget = row }
                    .padding(.horizontal, 16)
            }
            if let marker = segment.marker {
                ArcMarkerBar(marker: marker)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .padding(.top, 12)
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

// MARK: - Block card

private struct ArcBlockCard: View {
    let block: ArcTimelineBlock
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(block.leader?.i ?? "Block \(block.id)")
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer()
                    ArcBadgeView(state: block.badge)
                }
                HStack(spacing: 8) {
                    if block.rows.isEmpty {
                        // Per S23, a block can be deliberately leader-only with no member rows
                        // ever coming — say so plainly rather than reading as one still waiting.
                        Text("Leader only")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    } else {
                        Text("\(doneCount) / \(block.rows.count) done")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                    if let name = block.leader?.g?.name {
                        Text(name)
                            .font(PaiTypography.monoLabel.font)
                            .foregroundStyle(PaiPalette.Semantic.textFaint)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10).strokeBorder(PaiPalette.Semantic.borderDefault, lineWidth: 1)
            )
            .opacity(block.badge == .cancelled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("arc-block-\(block.id)")
    }

    private var doneCount: Int {
        block.rows.filter { $0.s == .done || $0.s == .cancelled }.count
    }
}

/// One of the five states a block's agent can be in, rendered as a small labelled dot — matches
/// `SessionStateIndicator`'s own "colour plus label, never colour alone" rule.
struct ArcBadgeView: View {
    let state: ArcBadgeState

    var body: some View {
        Label(text, systemImage: systemImage)
            .labelStyle(.titleAndIcon)
            .font(PaiTypography.captionEmphasized.font)
            .foregroundStyle(color)
            .accessibilityLabel(accessibilityText)
    }

    private var text: String {
        switch state {
        case .notSpawned: return "Not spawned"
        case .working: return "Working"
        case .returned: return "Returned"
        case .accepted: return "Accepted"
        case .cancelled: return "Cancelled"
        }
    }

    private var accessibilityText: String { "Agent status: \(text)" }

    private var systemImage: String {
        switch state {
        case .notSpawned: return "circle.dashed"
        case .working: return "gearshape.2.fill"
        case .returned: return "tray.and.arrow.down.fill"
        case .accepted: return "checkmark.circle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private var color: Color {
        switch state {
        case .notSpawned: return PaiPalette.Semantic.textMuted
        case .working: return PaiPalette.Semantic.accentText
        case .returned: return PaiPalette.Semantic.warningText
        case .accepted: return PaiPalette.green500
        case .cancelled: return PaiPalette.Semantic.textFaint
        }
    }
}

// MARK: - Loose row

private struct ArcLooseRowView: View {
    let row: ArcRow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "circle")
                    .font(.caption2)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                Text(row.i ?? "Row \(row.id)")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("arc-loose-row-\(row.id)")
    }
}
