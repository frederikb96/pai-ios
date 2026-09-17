import SwiftUI

/// The call screen's own settings button opens this — the full settings screen, in a sheet over
/// the call rather than a tear-down-and-navigate, so the call itself (pipeline, reply feed,
/// speech output) keeps running the whole time it is open, then Back returns to exactly the same
/// running call.
///
/// Wraps `SettingsScreen` almost unmodified rather than building a call-only subset: it needs its
/// own `NavigationStack` for a title bar and a Close button, since it is not reached through
/// `RootView`'s own stack here, and scrolls itself to the call-mode section on appear via the
/// anchor id `SettingsScreen` itself exposes — the one place that id is spelled, so the anchor and
/// the target can never drift apart. Sign out is hidden: it tears down the connection the running
/// call itself depends on, not a choice to offer from on top of it.
struct CallModeSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                SettingsScreen(hidesSignOut: true)
                    .onAppear { proxy.scrollTo(SettingsScreen.callModeSectionAnchorID, anchor: .top) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("call-mode-settings-done")
                }
            }
        }
        .accessibilityIdentifier("call-mode-settings-sheet")
    }
}
