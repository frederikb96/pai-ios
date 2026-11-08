import PAIKit
import SwiftUI

/// The agent's live browser sessions, those waiting on the owner first. Swift port of the list
/// half of `BrowserApp.tsx`, re-read every few seconds while on screen.
struct BrowserListScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var store: BrowserSessionsStore?

    private var me: MeStore? { environment.connection?.me }

    var body: some View {
        Group {
            if me?.isGuest == true {
                ContentUnavailableView(
                    "Owner Only", systemImage: "lock",
                    description: Text("Browser sessions can only be opened by the account owner."))
            } else if let store {
                list(store)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Browser")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("browser-list-screen")
        .task(id: me?.me != nil) {
            guard let connection = environment.connection, connection.me.me != nil, !connection.me.isGuest else {
                return
            }
            let current =
                store
                ?? BrowserSessionsStore(
                    api: connection.apiClient,
                    isOwner: { [weak identity = connection.me] in identity?.isOwner ?? false })
            store = current
            await current.keepFresh()
        }
    }

    @ViewBuilder
    private func list(_ store: BrowserSessionsStore) -> some View {
        List {
            if let error = store.errorMessage {
                Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
            }
            if let sessions = store.sessions {
                if sessions.isEmpty && store.errorMessage == nil {
                    Text("No browser session is open.").foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(sessions) { session in
                    Button {
                        environment.router.push(.browser(name: session.name))
                    } label: {
                        row(session)
                    }
                    .accessibilityIdentifier("browser-row-\(session.name)")
                }
            } else if store.errorMessage == nil {
                ProgressView()
            }
        }
        .listStyle(.plain)
        .refreshable { await store.load() }
    }

    private func row(_ session: BrowserSession) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: session.handoff != nil ? "hand.raised.fill" : "globe")
                .foregroundStyle(session.handoff != nil ? PaiPalette.amber500 : PaiPalette.Semantic.textMuted)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.displayTitle).font(PaiTypography.bodyEmphasized.font).lineLimit(1)
                Text(session.url)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
                if let handoff = session.handoff {
                    Text("Needs you: \(handoff.reason)")
                        .font(PaiTypography.captionEmphasized.font)
                        .foregroundStyle(PaiPalette.amber500)
                }
                Text(detail(session))
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
            }
        }
    }

    private func detail(_ session: BrowserSession) -> String {
        var parts = [ownerTitle(session.owner), session.name]
        if session.kept { parts.append("kept") }
        if let recording = session.recording { parts.append("recording \(recording.kind)") }
        if let date = IsoTimestamp.date(from: session.lastUsedAt) {
            parts.append(date.formatted(.relative(presentation: .named)))
        }
        return parts.joined(separator: " · ")
    }

    private func ownerTitle(_ owner: String?) -> String {
        guard let owner else { return "No conversation" }
        let conversation = environment.connection?.sessions.syncedSessions.first { $0.claudeSessionId == owner }
        return conversation.map(SessionListFormat.displayTitle(for:)) ?? String(owner.prefix(8))
    }
}
