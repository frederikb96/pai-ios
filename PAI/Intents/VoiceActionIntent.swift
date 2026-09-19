import AppIntents
import Foundation
import PAIKit

/// The Action Button's own binding — Freddy's Shortcut calls this. Toggles a running call
/// between recording and wake mode (Freddy's replacement for a hardware mute) without bringing
/// the app to the foreground, since a phone in a pocket is exactly what this exists for; with no
/// call running, it continues into the foreground and opens the launcher (``Route/quickActions``).
///
/// The two halves answer different questions and only the second one is a choice. Mid-call the
/// button has exactly one job and any screen at all would be wrong. Outside a call there is no
/// single right destination — home or fast, typed or spoken, a note — so it lands on the one
/// screen from which each of those is a single further press.
struct VoiceActionIntent: AppIntent {
    static var title: LocalizedStringResource { "Voice Action" }
    static var description: IntentDescription {
        IntentDescription("Toggles a running PAI call, or opens quick actions.")
    }

    /// Stays in the background for the toggle — `.dynamic` only brings the app forward on the
    /// launcher path below, never for the toggle itself.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        if let bridge = VoiceIntentBridge.shared.toggleCallMode, bridge() {
            return .result()
        }
        try await continueInForeground(alwaysConfirm: false)
        DeepLinkInbox.shared.receive(.quickActions)
        return .result()
    }
}
