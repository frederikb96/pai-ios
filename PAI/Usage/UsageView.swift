import PAIKit
import SwiftUI

extension UsagePaceTone {
    /// Each window is painted by its own distance from its steady-pace line (the server computes
    /// it and picks the steps); a window with no line is neutral rather than a guessed colour.
    /// iOS paints yellow and orange with the system colours because `PaiPalette` has no
    /// asset-catalog colorsets for them.
    var color: Color {
        switch self {
        case .green: return PaiPalette.green500
        case .yellow: return .yellow
        case .orange: return .orange
        case .red: return PaiPalette.red500
        case .neutral: return PaiPalette.surface500
        }
    }
}

/// Plan usage: the 5-hour, 7-day and per-model weekly windows, each against the even pace to its
/// reset. Swift port of `UsageApp.tsx`; the pace itself is the server's.
struct UsageView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: UsageStore?

    var body: some View {
        Group {
            if let store {
                content(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Usage")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("usage-screen")
        .task {
            guard store == nil, let client = environment.connection?.apiClient else { return }
            let newStore = UsageStore(api: client)
            store = newStore
            await newStore.load()
        }
    }

    @ViewBuilder
    private func content(_ store: UsageStore) -> some View {
        if store.isLoading && store.usage == nil {
            ProgressView()
        } else if let error = store.errorMessage, store.usage == nil {
            VStack(spacing: 8) {
                Text(error)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .multilineTextAlignment(.center)
                Button("Retry") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
        } else if store.rows.isEmpty {
            Text("Plan usage unknown — no agent has reported recently.")
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
        } else {
            List(store.rows) { row in
                UsageRowView(row: row)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .refreshable { await store.load() }
        }
    }
}

private struct UsageRowView: View {
    let row: UsageRow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.label)
                    .font(PaiTypography.bodyEmphasized.font)
                Spacer()
                Text("\(Int(row.utilization.rounded()))%")
                    .font(PaiTypography.panelTitle.font)
                    .monospacedDigit()
                    .foregroundStyle(row.tone.color)
            }
            bar
            Text(row.paceDescription ?? "No pace available for this window.")
                .font(PaiTypography.body.font)
                .foregroundStyle(row.tone.color)
            Text(resetLine)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("usage-row-\(row.id)")
    }

    /// The fill is the used share; the tick is the even-pace line.
    private var bar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(PaiPalette.surface500.opacity(0.2))
                Capsule()
                    .fill(PaiPalette.primary500)
                    .frame(width: geo.size.width * clamped(row.utilization))
                if let line = row.linePercent {
                    Rectangle()
                        .fill(PaiPalette.Semantic.textMuted)
                        .frame(width: 2, height: 14)
                        .offset(x: geo.size.width * clamped(line) - 1)
                }
            }
        }
        .frame(height: 14)
    }

    private func clamped(_ percent: Double) -> CGFloat {
        CGFloat(min(max(percent, 0), 100) / 100)
    }

    private var resetLine: String {
        guard let iso = row.resetsAt, let date = IsoTimestamp.date(from: iso) else { return "Not started" }
        return "Resets \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}
