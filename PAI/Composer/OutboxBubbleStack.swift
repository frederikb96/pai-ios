import PAIKit
import SwiftUI

/// This device's own outbound sends for a session, shown outside the transcript's own measured
/// `UICollectionView` — the mechanism that list guarantees for scrolling has no need to also carry
/// a bubble that changes shape while the user is looking at it. `OutboxStore.entries` is the single
/// source of truth: it exists before any request leaves and survives a reload, exactly the
/// property `ChatView.tsx`'s own `OutboxBubble` was built for.
///
/// A `.sent` entry is removed the moment the request answers (`OutboxStore.installHandover`) —
/// the transcript's own confirmed row, or `TranscriptStore.pendingBubbleTexts`' server-reported
/// list for a send from a different device, takes over showing it from there. Nothing here draws
/// a `.sent` entry.
struct OutboxBubbleStack: View {
    @Environment(OutboxStore.self) private var outbox
    @Environment(DraftStore.self) private var drafts
    /// `nil` is the new-session queue — a send composed before the session it will create exists,
    /// which has no session to be listed under and is visible on that screen alone.
    let sessionID: String?

    var body: some View {
        let queue = sessionID.map { outbox.entries(for: $0) } ?? outbox.newSessionEntries()
        let visible = queue.filter { $0.state != .sent }
        if !visible.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                ForEach(visible) { entry in
                    OutboxEntryBubbleView(entry: entry, drafts: drafts, outbox: outbox)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .accessibilityIdentifier("outbox-bubble-stack")
        }
    }
}

/// One outbox entry, drawn as itself rather than folded into an ordinary chat bubble — matching
/// `OutboxBubble.tsx`'s own reasoning: a queued or failed send is something the user can act on, not
/// a bubble that silently sits there or disappears.
///
/// No animation for `.sending`: a queued send can sit here for as long as the link is down, and a
/// spinner running for minutes costs real CPU for the whole time (see this repo's own rule against
/// an endlessly repeating animation). A static glyph carries the same information.
private struct OutboxEntryBubbleView: View {
    let entry: OutboxEntry
    let drafts: DraftStore
    let outbox: OutboxStore

    private var failed: Bool { entry.state == .failed }

    private var icon: String {
        switch entry.state {
        case .failed: "exclamationmark.circle.fill"
        case .sending: "paperplane.fill"
        case .queued, .sent: "clock.fill"
        }
    }

    private var label: String {
        switch entry.state {
        case .queued: "Waiting to send"
        case .sending: "Sending…"
        case .failed: entry.lastError ?? "Could not be sent"
        case .sent: ""
        }
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(entry.text)
                .font(PaiTypography.body.font)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    failed ? PaiPalette.Semantic.errorText : PaiPalette.primary500.opacity(0.6),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .frame(maxWidth: 280, alignment: .trailing)

            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(PaiTypography.caption.font)
            }
            .foregroundStyle(failed ? PaiPalette.Semantic.errorText : PaiPalette.Semantic.textSecondary)

            // Only a failed send offers these — a queued or sending one has nothing to retry yet
            // and nothing that has actually been lost to put back.
            if failed {
                HStack(spacing: 14) {
                    Button("Retry") { outbox.retry(id: entry.id) }
                    Button("Put back in composer") { putBackInComposer() }
                    Button("Discard") { outbox.discard(id: entry.id) }
                        .foregroundStyle(PaiPalette.Semantic.errorText)
                }
                .font(PaiTypography.captionEmphasized.font)
                .buttonStyle(.plain)
                .tint(PaiPalette.Semantic.accentText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityIdentifier("outbox-bubble-\(entry.state.rawValue)")
    }

    /// Mirrors the web's own `putBackInComposer`: the destroyed text goes back in front of
    /// whatever is already there, and the entry is gone either way — there is nothing left to
    /// retry once its words are back in the user's own hands.
    private func putBackInComposer() {
        let key = entry.draftKey
        let current = drafts.draft(for: key).text
        drafts.setDraftText(key: key, text: current.isEmpty ? entry.text : "\(entry.text)\n\n\(current)")
        outbox.discard(id: entry.id)
    }
}
