import PAIKit
import SwiftUI

/// The state dot every session row and the chat header render — one colour mapping and one pulse
/// animation, so neither ever drifts from the other. `SessionDotState.pulses` existed with no
/// view reading it; this is that view.
struct SessionDotView: View {
    let state: SessionDotState
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .modifier(PulseWhile(active: state.pulses))
    }

    /// Grey is normal, not an error — it means the session is not driven by the backend, true of
    /// a subagent and of anything Freddy runs in his own terminal.
    private var color: Color {
        switch state {
        case .starting: PaiPalette.blue400
        case .ready: PaiPalette.green500
        case .blocked: PaiPalette.amber500
        case .attention: PaiPalette.red500
        case .closed, .grey: PaiPalette.surface400
        case .legacyPending: PaiPalette.yellow500
        case .legacyActive: PaiPalette.blue500
        case .legacyCompleted: PaiPalette.green500
        case .legacyError: PaiPalette.red500
        case .legacyInterrupted: PaiPalette.orange500
        }
    }
}

/// A working session shows a spinner in the dot's own slot rather than beside it — sized to
/// match, so a working row is never taller than an idle one (the `scrolling` skill's constraint
/// on this list, ported from the web's identical 8px rule).
struct SessionStateIndicator: View {
    let dotState: SessionDotState
    let isWorking: Bool
    var size: CGFloat = 8

    var body: some View {
        if isWorking {
            ProgressView()
                .scaleEffect(size / 20)
                .tint(PaiPalette.green500)
                .frame(width: size, height: size)
                .accessibilityLabel("Working")
        } else {
            SessionDotView(state: dotState, size: size)
        }
    }
}

private struct PulseWhile: ViewModifier {
    let active: Bool
    @State private var isDimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(active && isDimmed ? 0.35 : 1)
            .onAppear { isDimmed = active }
            .onChange(of: active) { _, newValue in isDimmed = newValue }
            .animation(active ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: isDimmed)
    }
}
