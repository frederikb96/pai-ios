import AppIntents
import Foundation
import PAIKit

/// The Action Button's own binding — Freddy's Shortcut calls this, and lands on the launcher
/// (``Route/quickActions``): a phone in a pocket has no single right destination — home or fast,
/// typed or spoken, a note — so it opens the one screen from which each of those is a single
/// further press.
struct VoiceActionIntent: AppIntent {
    static var title: LocalizedStringResource { "Voice Action" }
    static var description: IntentDescription {
        IntentDescription("Opens quick actions.")
    }

    static var supportedModes: IntentModes { [.foreground(.dynamic)] }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await continueInForeground(alwaysConfirm: false)
        DeepLinkInbox.shared.receive(.quickActions)
        return .result()
    }
}
