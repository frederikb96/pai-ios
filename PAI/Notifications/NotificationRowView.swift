import PAIKit
import SwiftUI

/// One row in the notification centre. Unread state is a dot plus weight, never colour alone
/// (`MachineChip`'s own doc comment gives the same reasoning for the same accessibility concern),
/// and read rows dim — nothing is ever removed, this is a log.
///
/// A body is clamped to a few lines: one raised from a chat message carries the whole message.
/// A clamped body offers Show more, which opens the full text in place (an agent's as markdown);
/// a tap anywhere else on the row still opens the session at the message.
struct NotificationRowView: View {
    let notification: PaiNotification
    let isExpanded: Bool
    let onTap: () -> Void
    let onClearAlert: () async -> Void

    private static let bodyLineLimit = 4

    @State private var isBodyOpen = false
    @State private var clampedBodyHeight: CGFloat = 0
    @State private var fullBodyHeight: CGFloat = 0

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                unreadDot
                VStack(alignment: .leading, spacing: 4) {
                    header
                    bodyText
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

    /// An expanded alert shows its whole body too, as it always has.
    private var showsFullBody: Bool { isBodyOpen || isExpanded }

    /// Whether the clamp hid anything: the body laid out without a limit, in the background and
    /// unseen, is taller than the clamped one.
    private var isBodyClamped: Bool { fullBodyHeight > clampedBodyHeight + 0.5 }

    @ViewBuilder
    private var bodyText: some View {
        if showsFullBody {
            if notification.kind == .agent {
                MarkdownContentView(blocks: MarkdownParser.parse(notification.listBody))
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
            } else {
                Text(notification.listBody)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
            }
        } else {
            let preview = bodyPreview
            Text(preview)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
                .lineLimit(Self.bodyLineLimit)
                .onGeometryChange(for: CGFloat.self, of: \.size.height) { clampedBodyHeight = $0 }
                .background(alignment: .topLeading) {
                    Text(preview)
                        .font(PaiTypography.body.font)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { fullBodyHeight = $0 }
                }
        }
        if isBodyOpen || (!isExpanded && isBodyClamped) {
            Button(isBodyOpen ? "Show less" : "Show more") { isBodyOpen.toggle() }
                .buttonStyle(.borderless)
                .font(PaiTypography.captionEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.accentText)
                .accessibilityIdentifier("notification-body-toggle-\(notification.id)")
        }
    }

    /// The clamped lines read as text, not as markdown source: an agent's body is markdown, and
    /// its first lines would otherwise be asterisks and hashes.
    private var bodyPreview: String {
        notification.kind == .agent ? MarkdownParser.parse(notification.listBody).plainText : notification.listBody
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
            Text(notification.listTitle)
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
            if notification.taskName != nil || notification.sessionTitle != nil {
                HStack(spacing: 4) {
                    // The task whose run raised it, as on the web, ahead of the session title.
                    if let taskName = notification.taskName {
                        Text(taskName)
                            .lineLimit(1)
                            .padding(.horizontal, 4)
                            .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 4))
                            .accessibilityIdentifier("notification-task-chip")
                        if notification.sessionTitle != nil { Text("·") }
                    }
                    if let sessionTitle = notification.sessionTitle { Text(sessionTitle).lineLimit(1) }
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
        case "critical", "error": return PaiPalette.red500
        case "warning": return PaiPalette.amber500
        default: return PaiPalette.Semantic.textMuted
        }
    }

    private var relativeTime: String {
        SessionTimeFormat.text(for: notification.createdAt) ?? ""
    }
}
