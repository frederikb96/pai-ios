import PAIKit
import SwiftUI

/// The full player: scrubber, reply-to-reply buttons, autoplay, speed and the session's replies
/// with the ones already heard ticked. A sheet over the transcript.
struct PlaybackSheet: View {
    let sessionId: String

    @Environment(\.dismiss) private var dismiss
    @State private var dragMs: Double?

    private static let maxListed = 30

    private var controller: PlaybackController { .shared }

    var body: some View {
        let store = controller.store
        let current = store.current
        let shownSession = current?.sessionId ?? sessionId
        let replies = Array(controller.playableReplies(in: shownSession).suffix(Self.maxListed).reversed())
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(current: current, modeOn: store.isOn(shownSession))
                    scrubber(current: current)
                    transport(current: current, replies: replies)
                    options(store: store, session: shownSession)
                    repliesList(replies: replies, current: current, heard: store.heard)
                }
                .padding(16)
            }
            .navigationTitle("Playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("playback-sheet-done")
                }
            }
        }
        .accessibilityIdentifier("playback-sheet")
        .fixtureFact("playbackSheet", current?.title ?? "nothing playing")
    }

    @ViewBuilder
    private func header(current: PlaybackCurrent?, modeOn: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current {
                Text(current.title)
                    .font(PaiTypography.panelTitle.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(3)
                if let notice = current.notice {
                    Text(notice)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                } else if let voiceNote = current.voiceNote {
                    Text(voiceNote)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
            } else {
                Text(modeOn ? "Nothing playing. Pick a reply below." : "Playback is off for this session.")
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .frame(minHeight: 56, alignment: .topLeading)
    }

    private func scrubber(current: PlaybackCurrent?) -> some View {
        let duration = Double(max(current?.durationMs ?? 0, 1))
        let position = dragMs ?? Double(current?.positionMs ?? 0)
        return VStack(spacing: 2) {
            // A drag seeks once, on release: landing in a segment nobody has heard yet synthesises
            // it, so a seek per point would spend credits on the way.
            Slider(
                value: Binding(get: { min(position, duration) }, set: { dragMs = $0 }), in: 0...duration,
                onEditingChanged: { editing in
                    guard !editing, let target = dragMs else { return }
                    controller.seek(toMs: Int(target))
                    dragMs = nil
                }
            )
            .disabled(current == nil || (current?.durationMs ?? 0) == 0)
            .accessibilityLabel("Position in this reply")
            HStack {
                Text(PlaybackModel.formatClock(Int(position)))
                Spacer()
                Text(PlaybackModel.formatClock(current?.durationMs ?? 0))
            }
            .font(PaiTypography.caption.font)
            .monospacedDigit()
            .foregroundStyle(PaiPalette.Semantic.textMuted)
        }
    }

    private func transport(current: PlaybackCurrent?, replies: [Message]) -> some View {
        let at = replies.firstIndex { $0.id == current?.messageId }
        return HStack {
            roundButton("backward.end.fill", "Previous reply", enabled: at.map { $0 < replies.count - 1 } ?? false) {
                controller.stepReply(-1)
            }
            Spacer()
            roundButton("gobackward.10", "Back 10 seconds", enabled: current != nil) {
                controller.skip(byMs: -PlaybackModel.skipMs)
            }
            Spacer()
            Button {
                controller.toggle()
            } label: {
                Image(systemName: (current?.isPlayingOrStarting ?? false) ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(PaiPalette.primary500, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(current == nil)
            .opacity(current == nil ? 0.3 : 1)
            .accessibilityLabel((current?.isPlayingOrStarting ?? false) ? "Pause" : "Play")
            Spacer()
            roundButton("goforward.10", "Forward 10 seconds", enabled: current != nil) {
                controller.skip(byMs: PlaybackModel.skipMs)
            }
            Spacer()
            roundButton("forward.end.fill", "Next reply", enabled: at.map { $0 > 0 } ?? false) {
                controller.stepReply(1)
            }
        }
    }

    private func roundButton(_ systemImage: String, _ label: String, enabled: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .foregroundStyle(PaiPalette.Semantic.textSecondary)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
        .accessibilityLabel(label)
    }

    private func options(store: PlaybackStore, session: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if store.isOn(session) { AutoplaySwitch(sessionId: session) }
            HStack(spacing: 4) {
                ForEach(PlaybackModel.speeds, id: \.self) { value in
                    Button {
                        controller.setSpeed(value)
                    } label: {
                        Text("\(value.formatted())×")
                            .font(PaiTypography.caption.font)
                            .monospacedDigit()
                            .frame(minWidth: 40, minHeight: 32)
                            .foregroundStyle(store.speed == value ? Color.white : PaiPalette.Semantic.textSecondary)
                            .background(
                                store.speed == value ? PaiPalette.Semantic.textPrimary : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(store.speed == value ? .isSelected : [])
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Your speed, on every device")
        }
    }

    @ViewBuilder
    private func repliesList(replies: [Message], current: PlaybackCurrent?, heard: [Int]) -> some View {
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("REPLIES")
                    .font(PaiTypography.captionEmphasized.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                ForEach(replies) { message in
                    let isCurrent = message.id == current?.messageId
                    Button {
                        controller.playReply(
                            sessionId: message.sessionId, messageId: message.id,
                            title: PlaybackModel.snippet(of: message))
                    } label: {
                        HStack(spacing: 8) {
                            Group {
                                if isCurrent {
                                    Image(systemName: "play.fill").foregroundStyle(PaiPalette.primary500)
                                } else if heard.contains(message.id) {
                                    Image(systemName: "checkmark").foregroundStyle(PaiPalette.green500)
                                } else {
                                    Color.clear
                                }
                            }
                            .frame(width: 20)
                            Text(PlaybackModel.snippet(of: message, max: 90))
                                .font(PaiTypography.body.font)
                                .foregroundStyle(
                                    isCurrent ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textPrimary
                                )
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
