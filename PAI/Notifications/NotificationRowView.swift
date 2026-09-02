import PAIKit
import SwiftUI

/// One row in the notification centre. Unread state is a dot plus weight, never colour alone
/// (`MachineChip`'s own doc comment gives the same reasoning for the same accessibility concern),
/// and read rows dim — nothing is ever removed, this is a log.
struct NotificationRowView: View {
    let notification: PaiNotification
    let isExpanded: Bool
    let onTap: () -> Void
    let onClearAlert: () async -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                unreadDot
                VStack(alignment: .leading, spacing: 4) {
                    header
                    Text(notification.body)
                        .font(PaiTypography.body.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                        .lineLimit(isExpanded ? nil : 2)
                    footer
                    if notification.kind == .alert, isExpanded {
                        alertDetail
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 6)
        .accessibilityIdentifier("notification-row-\(notification.id)")
    }

    private var unreadDot: some View {
        Circle()
            .fill(notification.isUnread ? PaiPalette.primary500 : .clear)
            .frame(width: 6, height: 6)
            .padding(.top, 6)
            .accessibilityHidden(true)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: kindIconName)
                .foregroundStyle(kindIconColor)
            Text(notification.title)
                .font(notification.isUnread ? PaiTypography.body.font.weight(.medium) : PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(relativeTime)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch notification.kind {
        case .agent:
            if let sessionTitle = notification.sessionTitle {
                HStack(spacing: 4) {
                    Text(sessionTitle).lineLimit(1)
                    // The affordance is quiet on purpose — a tap anywhere on the row already
                    // does this; this is just what tells the reader it will.
                    if notification.anchor != nil {
                        Text("· jump to message")
                    }
                }
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        case .alert:
            if let alert = notification.alert {
                Text("\(alert.key) · \(alert.active ? "still active" : "resolved")")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
    }

    /// Only shown once the row is expanded — the alert's key, severity and whether it is still
    /// active, plus a Clear button when it is. This is the first place any alert becomes
    /// actionable from a phone.
    private var alertDetail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Severity: \(notification.alert?.severity ?? "unknown")")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            if notification.alert?.active == true {
                Button {
                    Task { await onClearAlert() }
                } label: {
                    Text("Clear")
                }
                .buttonStyle(.bordered)
                .tint(PaiPalette.amber500)
                .accessibilityIdentifier("notification-clear-alert-\(notification.id)")
            }
        }
        .padding(.top, 2)
    }

    private var kindIconName: String {
        switch notification.kind {
        case .agent: "bell"
        case .alert: "exclamationmark.triangle.fill"
        }
    }

    private var kindIconColor: Color {
        guard notification.kind == .alert else { return PaiPalette.Semantic.textMuted }
        switch notification.alert?.severity {
        case "critical", "error": PaiPalette.red500
        case "warning": PaiPalette.amber500
        default: PaiPalette.Semantic.textMuted
        }
    }

    private var relativeTime: String {
        SessionTimeFormat.text(for: notification.createdAt) ?? ""
    }
}
