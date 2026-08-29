import PAIKit
import SwiftUI

/// A session's terminal, read-only.
///
/// The pane is fixed at 200 columns with no resize endpoint, so a phone cannot make it fit and
/// horizontal scrolling is the honest answer rather than reflowing.
struct TerminalScreen: View {
    let sessionID: String

    var body: some View {
        Text("Terminal")
            .font(PaiTypography.monoLabel.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
            .navigationTitle("Terminal")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("terminal-screen")
    }
}
