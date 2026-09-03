import PAIKit
import SwiftUI

/// Where "Spec" (from a session row's trailing swipe or the in-session right-to-left swipe)
/// leads: the specs bound to that session's conversation, so a single bound spec goes straight
/// to `ArcSpecView` and anything else — none, several, or a fetch failure — gets a small sheet
/// instead of guessing.
struct ArcSpecPickerSheet: View {
    /// `Session.claudeSessionId` — `nil` for a session that has never registered a conversation
    /// yet, which cannot be bound to anything.
    let claudeSessionID: String?
    let onSelect: (String) -> Void

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @State private var specs: [ArcSpec]?
    @State private var didFail = false

    var body: some View {
        NavigationStack {
            Group {
                if claudeSessionID == nil {
                    notice("This session is not running under an ARC spec.")
                } else if let specs {
                    if specs.isEmpty {
                        notice("This session is not running under an ARC spec.")
                    } else {
                        specList(specs)
                    }
                } else if didFail {
                    notice("Could not check for a bound spec.")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Spec")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .task {
            guard let claudeSessionID, let client = environment.connection?.apiClient else { return }
            let boundSpecs = ArcBoundSpecsStore(api: client)
            if let result = await boundSpecs.boundSpecs(session: claudeSessionID) {
                specs = result
            } else {
                didFail = true
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("arc-spec-picker")
    }

    private func specList(_ specs: [ArcSpec]) -> some View {
        List(specs) { spec in
            Button {
                let uuid = spec.uuid
                dismiss()
                onSelect(uuid)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(spec.name)
                        .font(PaiTypography.bodyEmphasized.font)
                        .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Text(spec.phase)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }
        }
    }

    private func notice(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "shippingbox")
                .font(.title2)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            Text(text)
                .font(PaiTypography.body.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The `.sheet(item:)` target for `ArcSpecPickerSheet`, carrying whichever session it was opened
/// for — a plain `String?` cannot be a sheet item, and `Identifiable` needs something to key on
/// even when there is no conversation id yet.
struct ArcSpecPickerTarget: Identifiable {
    let sessionID: String
    let claudeSessionID: String?
    var id: String { sessionID }
}

extension View {
    /// Wires `ArcSpecPickerSheet` to a binding, and routes a picked spec to `ArcSpecView` via
    /// the app router. Shared by the session list's swipe action and the in-session swipe menu
    /// so the two entry points behave identically rather than drifting into two copies of this
    /// wiring.
    func arcSpecPicker(_ target: Binding<ArcSpecPickerTarget?>, router: Router) -> some View {
        sheet(item: target) { value in
            ArcSpecPickerSheet(claudeSessionID: value.claudeSessionID) { specUuid in
                router.push(.arcSpec(specUuid: specUuid))
            }
        }
    }
}
