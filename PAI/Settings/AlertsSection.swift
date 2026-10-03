import PAIKit
import SwiftUI

/// Backend alerts that have failed and not recovered. Acknowledging frees an alert's key — it is
/// not a fix, and the same fault raises it again.
struct AlertsSection: View {
    let alerts: AlertsStore

    var body: some View {
        Section {
            if let open = alerts.alerts {
                if open.isEmpty {
                    Text("No active alerts.")
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                        .accessibilityIdentifier("alerts-empty")
                } else {
                    ForEach(open) { alert in
                        AlertRow(alert: alert, disabled: alerts.isClearing) {
                            Task { await alerts.acknowledge(alert.id) }
                        }
                    }
                }
            }
            if let error = alerts.errorMessage {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        } header: {
            HStack {
                Text("Alerts")
                Spacer()
                if (alerts.alerts?.count ?? 0) > 1 {
                    Button("Acknowledge all") { Task { await alerts.acknowledgeAll() } }
                        .disabled(alerts.isClearing)
                        .textCase(nil)
                        .accessibilityIdentifier("alerts-acknowledge-all")
                }
            }
        }
        .task { await alerts.load() }
    }
}

private struct AlertRow: View {
    let alert: PaiAlert
    let disabled: Bool
    let acknowledge: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(alert.message)
            Text(detail)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Button("Acknowledge", action: acknowledge)
                .disabled(disabled)
                .accessibilityLabel("Acknowledge \(alert.key)")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("alert-row")
    }

    private var detail: String {
        var parts = [alert.source, alert.key, alert.severity]
        if alert.count > 1 { parts.append("\(alert.count)×") }
        if let date = IsoTimestamp.date(from: alert.lastSeenAt) {
            parts.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        return parts.joined(separator: " · ")
    }
}
