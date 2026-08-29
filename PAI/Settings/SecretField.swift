import PAIKit
import SwiftUI

/// The shape the ElevenLabs key and the SMTP password share: presence is readable, the value
/// never is. Built once (`WriteOnlySecretField` in PAIKit owns the state; this owns the chrome)
/// and reused by both call sites rather than duplicated.
///
/// Three states: unknown (`status == nil`, before the launch-time presence fetch answers) shows
/// nothing rather than guessing; set shows `••••••••••` plus Replace/Clear; unset — or mid-Replace
/// — shows a plain input plus Save.
struct SecretField: View {
    let title: String
    let identifier: String
    let field: WriteOnlySecretField

    @State private var pendingValue = ""
    @State private var isReplacing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.Semantic.textPrimary)

            if let status = field.status, status.set, !isReplacing {
                setRow(status)
            } else {
                unsetRow
            }

            if let error = field.errorMessage {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
        }
        .accessibilityIdentifier(identifier)
    }

    private func setRow(_ status: SecretStatus) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("••••••••••")
                    .font(PaiTypography.monoLabel.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                if let updatedAt = status.updatedAt {
                    Text("Updated \(formatted(updatedAt))")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                }
            }

            Spacer()

            Button("Replace") {
                pendingValue = ""
                isReplacing = true
            }
            .accessibilityIdentifier("\(identifier)-replace")

            Button("Clear", role: .destructive) {
                Task { await field.clear() }
            }
            .disabled(field.isSaving)
            .accessibilityIdentifier("\(identifier)-clear")
        }
    }

    private var unsetRow: some View {
        HStack(spacing: 12) {
            SecureField("Value", text: $pendingValue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("\(identifier)-input")

            Button("Save") {
                Task {
                    await field.save(value: pendingValue)
                    if field.status?.set == true {
                        pendingValue = ""
                        isReplacing = false
                    }
                }
            }
            .disabled(pendingValue.isEmpty || field.isSaving)
            .accessibilityIdentifier("\(identifier)-save")
        }
    }

    /// The backend sends ISO-8601; a raw string is still shown if parsing fails, rather than
    /// hiding the timestamp Freddy asked to see beside the dots.
    private func formatted(_ raw: String) -> String {
        guard let date = Self.isoFormatter.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static let isoFormatter = ISO8601DateFormatter()
}
