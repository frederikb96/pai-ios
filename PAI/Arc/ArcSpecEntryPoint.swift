import PAIKit
import SwiftUI

/// Where "Spec" (from a session row's trailing swipe or the in-session right-to-left swipe)
/// resolves to — computed BEFORE anything is shown, so a session bound to exactly one spec goes
/// straight to `ArcSpecView` and never sees a picker at all. Mirrors the web's own
/// `openArcForSession`, which does the identical lookup-then-decide before navigating rather than
/// opening a sheet that only decides once its own fetch resolves.
enum ArcSpecResolution: Identifiable {
    /// Several bound specs — offer a choice.
    case multiple([ArcSpec])
    /// Nothing bound (or no conversation to check at all).
    case none
    /// The check itself failed.
    case failed

    var id: String {
        switch self {
        case .multiple: return "multiple"
        case .none: return "none"
        case .failed: return "failed"
        }
    }
}

/// Fetches the specs bound to `claudeSessionID` and decides what "Spec" does: exactly one match
/// pushes straight there and returns `nil` (nothing left to present), several return `.multiple`
/// for the caller to show as a sheet, and zero / a failed check return `.none` / `.failed` for
/// the same small notice sheet as before. Shared by both entry points
/// (`SessionListView`'s swipe, `SessionDetailView`'s swipe menu) so they behave identically
/// rather than drifting into two copies of this decision.
@MainActor
func resolveArcSpec(claudeSessionID: String?, api: PaiApiClient?, router: Router) async -> ArcSpecResolution? {
    guard let claudeSessionID, let api else { return .none }
    guard let specs = await ArcBoundSpecsStore(api: api).boundSpecs(session: claudeSessionID) else { return .failed }
    if specs.isEmpty { return .none }
    if specs.count == 1 {
        router.push(.arcSpec(specUuid: specs[0].uuid))
        return nil
    }
    return .multiple(specs)
}

/// The sheet shown only for `.multiple` / `.none` / `.failed` — the single-spec case never
/// reaches this at all, having already been pushed directly by `resolveArcSpec`.
struct ArcSpecPickerSheet: View {
    let resolution: ArcSpecResolution
    let onSelect: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch resolution {
                case .none:
                    notice("This session is not running under an ARC spec.")
                case .failed:
                    notice("Could not check for a bound spec.")
                case .multiple(let specs):
                    specList(specs)
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
        .presentationDetents([.medium])
        .accessibilityIdentifier("arc-spec-picker")
    }

    private func specList(_ specs: [ArcSpec]) -> some View {
        List(specs) { spec in
            Button {
                // Push before dismissing — see `CreateSessionView`'s own comment on this exact
                // order: a push onto the stack behind a sheet that is mid-dismissal is dropped
                // often enough to be a known iOS trap, and the failure is silent.
                onSelect(spec.uuid)
                dismiss()
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

extension View {
    /// Wires `ArcSpecPickerSheet` to a binding, and routes a picked spec to `ArcSpecView` via
    /// the app router. Shared by the session list's swipe action and the in-session swipe menu
    /// so the two entry points behave identically rather than drifting into two copies of this
    /// wiring.
    func arcSpecPicker(_ target: Binding<ArcSpecResolution?>, router: Router) -> some View {
        sheet(item: target) { resolution in
            ArcSpecPickerSheet(resolution: resolution) { specUuid in
                router.push(.arcSpec(specUuid: specUuid))
            }
        }
    }
}
