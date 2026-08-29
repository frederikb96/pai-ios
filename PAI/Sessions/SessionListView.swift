import PAIKit
import SwiftUI

/// The app's first screen.
struct SessionListView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(SessionListStore.self) private var sessions

    var body: some View {
        List(sessions.rows) { row in
            Button {
                environment.router.push(.session(id: row.id))
            } label: {
                SessionRow(row: row)
            }
            .accessibilityIdentifier("session-row-\(row.id)")
        }
        .listStyle(.plain)
        .navigationTitle("Sessions")
        .accessibilityIdentifier("session-list")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    environment.router.push(.settings)
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityIdentifier("open-settings")
            }
        }
        .task {
            await sessions.loadInitialSessions()
            sessions.startPolling()
        }
        .onDisappear { sessions.stopPolling() }
    }
}

/// One row: state dot, warnings, title, when it last did anything.
///
/// Deliberately spare, matching the web. The machine a session runs on is **not** shown, so with
/// no machine filter applied a VM row and a laptop row look identical — that is the web's choice
/// and changing it is an addition, not a port.
struct SessionRow: View {
    let row: SessionListRow

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(dotColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayTitle)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(1)

                if let activity = row.lastActivityAt {
                    Text(activity)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            if row.showsBlockedWarning {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(PaiPalette.Semantic.warningText)
            }
            if row.showsAttentionWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
            if row.showsTokenCount {
                Text("\(row.sessionTokens)")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .padding(.vertical, 2)
    }

    /// Grey is normal, not an error — it means the session is not driven by the backend, which is
    /// true of a subagent and of anything Freddy runs in his own terminal.
    private var dotColor: Color {
        switch row.dotState {
        case .ready, .legacyActive: PaiPalette.green500
        case .starting, .blocked, .legacyPending: PaiPalette.amber500
        case .attention, .legacyError: PaiPalette.red500
        case .closed, .grey, .legacyCompleted, .legacyInterrupted: PaiPalette.surface400
        }
    }
}
