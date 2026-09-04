import PAIKit
import SwiftUI

/// Where the top bar's "Apps" button leads — a small picker over the two things that used to
/// have their own toolbar icon or are being added here: Arc and Notes. Mirrors the web's own
/// `AppsFlyout`/`AppsHome` pairing (a modal listing every registered app), minus Memory and
/// Notifications: PAI Cloud's Memory app is notes plus projects/phases/search, and this repo
/// never built a separate Memory screen — the note index (`.notes`) is the one entry point this
/// app already has for it, so it is what "memory, reachable under Apps" means here. Notifications
/// keeps its own always-visible top bar icon (row 87's note): unlike Arc and Notes, it carries a
/// live unread badge that would otherwise be hidden a tap deeper.
struct AppsHomeSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button(action: openArc) {
                    Label("Arc", systemImage: "shippingbox")
                }
                .accessibilityIdentifier("apps-open-arc")
                Button(action: openNotes) {
                    Label("Notes", systemImage: "note.text")
                }
                .accessibilityIdentifier("apps-open-notes")
            }
            .listStyle(.plain)
            .navigationTitle("Apps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
        .accessibilityIdentifier("apps-sheet")
    }

    // Push before dismissing, in both handlers below — the same order `CreateSessionView` uses
    // and documents on itself: a push onto the stack behind a sheet that is mid-dismissal is
    // dropped often enough to be a known iOS trap, and the failure is silent. Reversing the order
    // would leave Freddy looking at the session list with the Apps sheet merely closed, having to
    // tap the destination a second time.
    private func openArc() {
        environment.router.push(.arcSpecList)
        dismiss()
    }

    private func openNotes() {
        environment.router.push(.notes)
        dismiss()
    }
}
