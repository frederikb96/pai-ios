import PAIKit
import SwiftUI

/// Proves the microphone is still capturing while there is nothing else on screen that can —
/// shown while dictating and not in the ordinary connected `.recording` state (connecting,
/// reconnecting, paused, or transcription stopped), since that is exactly when no new committed
/// word can arrive to prove it another way. See `MicrophoneHealthState`'s own doc comment for why
/// "quiet" and "not hearing" are two different states rather than one amplitude reading.
///
/// 🚨 Data-driven, never decorative: the bars redraw only when `controller.currentLevel` actually
/// changes (the same ~100ms cadence buffers arrive at), and a flat input draws a flat line — there
/// is no `Animation.repeatForever` or `Timer` running underneath it, matching pai-cloud's own
/// measured rule against perpetual animation for exactly this CPU-cost reason.
struct VoiceVolumeOverlay: View {
    let controller: VoiceRecorderController

    /// Recent levels, oldest first — a fixed-size ring rather than a `Timer`-driven sampler, so
    /// the number of bars drawn is exactly the number of buffers actually received.
    @State private var history: [Double] = []
    private static let barCount = 24

    var body: some View {
        HStack(spacing: 8) {
            icon
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 28)
        .onChange(of: controller.currentLevel) { _, newValue in
            guard case .hearing = controller.microphoneHealth else { return }
            history.append(newValue)
            if history.count > Self.barCount { history.removeFirst(history.count - Self.barCount) }
        }
        .onChange(of: controller.microphoneHealth) { _, health in
            // A quiet or dead reading is a flat line, not a stale waveform from before the room
            // went silent — clearing here is what keeps "flat input, flat line" honest across a
            // state change rather than only within one.
            if health != .hearing(level: controller.currentLevel) { history = [] }
        }
        .accessibilityIdentifier("voice-volume-overlay")
    }

    @ViewBuilder
    private var icon: some View {
        switch controller.microphoneHealth {
        case .hearing, .quiet:
            Image(systemName: "mic.fill")
                .foregroundStyle(PaiPalette.Semantic.textSecondary)
        case .notHearing:
            Image(systemName: "mic.slash.fill")
                .foregroundStyle(PaiPalette.Semantic.errorText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.microphoneHealth {
        case .hearing:
            waveform
        case .quiet:
            flatLine
        case .notHearing:
            Text("Not hearing you — check the microphone")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.errorText)
                .lineLimit(1)
        }
    }

    private var waveform: some View {
        GeometryReader { proxy in
            let barWidth = proxy.size.width / CGFloat(Self.barCount)
            HStack(alignment: .center, spacing: 0) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(PaiPalette.primary500)
                        .frame(width: max(1, barWidth - 2), height: max(2, proxy.size.height * CGFloat(level) * 4))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }

    /// A quiet room — one still line, not zero bars, so this reads as "listening, nothing said"
    /// rather than as the overlay having stopped drawing at all.
    private var flatLine: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(PaiPalette.Semantic.textFaint)
            .frame(height: 2)
    }
}
