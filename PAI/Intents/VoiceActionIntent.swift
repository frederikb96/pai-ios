import AppIntents
import Foundation
import PAIKit

/// The Action Button's own binding — Freddy's Shortcut calls this. Toggles a running call
/// between recording and wake mode (Freddy's replacement for a hardware mute) without bringing
/// the app to the foreground, since a phone in a pocket is exactly what this exists for; with no
/// call running, it continues into the foreground and opens a fast session instead, the same
/// launch ``NewFastSessionIntent`` already gives.
///
/// 🚨 Unverified beyond syntax — the app target compiles nowhere but a macOS run, and this is the
/// one file in the block whose API surface (`IntentModes`, `requestToContinueInForeground()`)
/// could only be read from documentation, never exercised against a compiler.
struct VoiceActionIntent: AppIntent {
    static var title: LocalizedStringResource { "Voice Action" }
    static var description: IntentDescription {
        IntentDescription("Toggles a running PAI call, or starts a fast session.")
    }

    /// Stays in the background for the toggle — `.dynamic` only brings the app forward when this
    /// continues into `NewSessionLaunchChoice.persist`'s own path below, never for the toggle
    /// itself.
    static var supportedModes: IntentModes { [.background, .foreground(.dynamic)] }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        if let bridge = VoiceIntentBridge.shared.toggleCallMode, bridge() {
            return .result()
        }
        try await requestToContinueInForeground()
        await NewSessionLaunchChoice.persist(sessionType: "fast", workingDir: nil)
        DeepLinkInbox.shared.receive(.createSession)
        return .result()
    }
}
