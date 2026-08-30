import PAIKit
import SwiftUI

/// Renders `ToastCenter`'s queue above everything else, bottom-anchored — the one place a toast
/// mounts, matching the web's single `ToastContainer`. Nothing existed here before this; every
/// failure the session actions menu can hit needed somewhere to land other than inline text in
/// whichever view happened to cause it.
struct ToastOverlay: View {
    let toasts: ToastCenter

    var body: some View {
        VStack(spacing: 8) {
            ForEach(toasts.toasts) { toast in
                ToastRow(toast: toast, onDismiss: { toasts.dismiss(toast.id) })
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .animation(.default, value: toasts.toasts.map(\.id))
        .allowsHitTesting(!toasts.toasts.isEmpty)
    }
}

private struct ToastRow: View {
    let toast: ToastMessage
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(toast.text)
                .font(PaiTypography.body.font)
                .foregroundStyle(.white)
                .lineLimit(2)

            Spacer(minLength: 0)

            if let action = toast.action {
                Button(action.label) {
                    action.handler()
                    onDismiss()
                }
                .font(PaiTypography.bodyEmphasized.font)
                .foregroundStyle(PaiPalette.primary400)
            }

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(backgroundColor, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8, y: 2)
        .accessibilityIdentifier("toast-\(toast.kind == .error ? "error" : "info")")
    }

    private var backgroundColor: Color {
        toast.kind == .error ? PaiPalette.red600 : PaiPalette.surface800
    }
}
