import PAIKit
import SwiftUI

/// The row above a transcript that says what a blocked session is waiting on, and answers it.
/// Swift port of `BlockerBanner.tsx`; which banner appears, and its wording, is
/// `BlockerBannerContent`.
///
/// Always in the hierarchy, drawing nothing while the session waits on nothing, so the store's
/// in-flight answer or restart outlives the banner appearing and disappearing around it.
///
/// A sibling row of the transcript rather than an overlay: the question is usually about the last
/// message, so it must not cover it. The question scrolls inside a bounded height so a long
/// permission prompt cannot push the transcript off a phone.
struct SessionBlockerBanner: View {
    @Environment(ToastCenter.self) private var toasts
    @Environment(SessionListStore.self) private var sessions
    @State private var store: BlockerBannerStore
    let sessionID: String
    let onOpenTerminal: () -> Void

    private static let questionMaxHeight: CGFloat = 160

    init(
        sessionID: String, sessionList: SessionListStore, api: any BlockerBannerApiClient,
        onOpenTerminal: @escaping () -> Void
    ) {
        _store = State(initialValue: BlockerBannerStore(sessionId: sessionID, sessionList: sessionList, api: api))
        self.sessionID = sessionID
        self.onOpenTerminal = onOpenTerminal
    }

    var body: some View {
        if let session = sessions.session(withId: sessionID),
            let content = BlockerBannerContent.make(state: session.state, blocker: session.blocker)
        {
            banner(content)
        }
    }

    @ViewBuilder
    private func banner(_ content: BlockerBannerContent) -> some View {
        switch content {
        case .signInWait:
            note(
                icon: "key.fill", tone: .amber,
                text:
                    "Waiting for the Claude sign-in above. This session picks up where it left off as soon as that is done.",
                identifier: "blocker-banner-sign-in")
        case .autoConfirmed(let text):
            note(icon: "checkmark.shield", tone: .accent, text: text, identifier: "blocker-banner-confirmed")
        case .unreachable(let paneText):
            unreachable(paneText)
        case .question(let text, let options, let severity):
            question(text, options: options, severity: severity)
        case .terminalOnly(let message):
            VStack(alignment: .leading, spacing: 8) {
                header(icon: "exclamationmark.circle", tone: .red) {
                    Text(message).font(PaiTypography.bodyEmphasized.font)
                }
                terminalButton
            }
            .bannerChrome(tone: .red, identifier: "blocker-banner-terminal-only")
        }
    }

    private func note(icon: String, tone: BannerTone, text: String, identifier: String) -> some View {
        header(icon: icon, tone: tone) {
            Text(text).font(PaiTypography.bodyEmphasized.font)
        }
        .bannerChrome(tone: tone, identifier: identifier)
    }

    private func unreachable(_ paneText: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(icon: "powerplug", tone: .red) {
                Text(
                    "PAI can't reach this session — it never found its Remote Control connection, so anything you send waits instead of arriving."
                )
                .font(PaiTypography.bodyEmphasized.font)
            }
            if !paneText.isEmpty {
                scrollingText(paneText, font: PaiTypography.caption.font.monospaced(), tone: .red)
            }
            HStack(spacing: 8) {
                Button {
                    Task { await store.restart(toasts: toasts) }
                } label: {
                    Text(store.isRestarting ? "Restarting…" : "Restart session")
                }
                .buttonStyle(.borderedProminent)
                .tint(BannerTone.red.accentColor)
                .disabled(store.isBusy)
                .accessibilityIdentifier("blocker-restart")
                terminalButton
            }
        }
        .bannerChrome(tone: .red, identifier: "blocker-banner-not-registered")
    }

    private func question(_ text: String, options: [BlockerOption], severity: BlockerBannerContent.Severity)
        -> some View
    {
        let tone: BannerTone = severity == .warning ? .amber : .red
        return VStack(alignment: .leading, spacing: 8) {
            header(icon: severity == .warning ? "exclamationmark.triangle" : "exclamationmark.circle", tone: tone) {
                scrollingText(text, font: PaiTypography.bodyEmphasized.font, tone: tone)
            }
            // One full-width button per option: labels run to sentences ("Yes, and don't ask again
            // for …"), and a thumb needs the whole row.
            ForEach(options, id: \.key) { option in
                Button {
                    Task { await store.answer(option.key, toasts: toasts) }
                } label: {
                    Text(store.answeringKey == option.key ? "Sending…" : option.label)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(tone.accentColor)
                .disabled(store.isBusy)
                .accessibilityIdentifier("blocker-option-\(option.key)")
            }
            terminalButton
        }
        .bannerChrome(tone: tone, identifier: "blocker-banner-question")
    }

    private var terminalButton: some View {
        Button {
            onOpenTerminal()
        } label: {
            Label("Open terminal", systemImage: "terminal")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("blocker-open-terminal")
    }

    private func header<Content: View>(icon: String, tone: BannerTone, @ViewBuilder _ content: () -> Content)
        -> some View
    {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tone.iconColor)
            content()
                .foregroundStyle(tone.titleColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Short text lays out at its natural height; text taller than `questionMaxHeight` scrolls.
    private func scrollingText(_ text: String, font: Font, tone: BannerTone) -> some View {
        ViewThatFits(in: .vertical) {
            Text(text).font(font)
            ScrollView { Text(text).font(font).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .frame(maxHeight: Self.questionMaxHeight)
        .foregroundStyle(tone.titleColor)
        .textSelection(.enabled)
    }
}

extension View {
    /// The banner chrome: a tinted, bordered panel inset from the screen edges.
    fileprivate func bannerChrome(tone: BannerTone, identifier: String) -> some View {
        self
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone.background, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(tone.border))
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
    }
}
