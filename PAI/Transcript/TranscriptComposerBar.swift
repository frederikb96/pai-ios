import PAIKit
import SwiftUI

/// A minimal way to send plain text into a session.
///
/// Row 59 ("Composer — send, attach, and the action menu") owns the real composer — attachments,
/// drafts, voice, the action menu — and is a separate, not-yet-built block. This exists so the
/// transcript screen this block is responsible for is not otherwise unusable, and it deliberately
/// stops at what `TranscriptStore`'s already-built send-confirmation state needs: a text field and
/// a send button, wired to `trackSend` exactly the way its own doc comment describes.
struct TranscriptComposerBar: View {
    let sessionID: String
    let store: TranscriptStore
    let apiClient: PaiApiClient

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            pendingBubbles
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(PaiTypography.body.font)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(PaiPalette.Semantic.raisedSurface, in: RoundedRectangle(cornerRadius: 18))
                    .lineLimit(1...6)
                    .focused($isFocused)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundStyle(canSend ? PaiPalette.primary500 : PaiPalette.Semantic.textFaint)
                }
                .disabled(!canSend)
                .accessibilityIdentifier("composer-send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var pendingBubbles: some View {
        let pending = store.pendingBubbleTexts(sessionId: sessionID)
        if !pending.isEmpty {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(pending.enumerated()), id: \.offset) { _, bubbleText in
                    Text(bubbleText)
                        .font(PaiTypography.body.font)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, TranscriptRowMetrics.bubbleVerticalPadding / 2)
                        .background(PaiPalette.primary500.opacity(0.6), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        text = ""
        let task = Task { try await apiClient.postMessage(sessionId: sessionID, message: trimmed) }
        store.trackSend(sessionId: sessionID, text: trimmed, send: task)
    }
}
