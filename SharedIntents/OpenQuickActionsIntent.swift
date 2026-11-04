import AppIntents
import Foundation
import PAIKit

// Compiled into the app and into the controls extension. A control that opens the app runs its
// intent in the app's process only when the app holds the very same type; with the intent in the
// extension alone, tapping the control fails without ever bringing the app forward.

/// Open the six-tile launcher — what the hardware Action Button lands on, what the Quick actions
/// control opens, and available to Shortcuts on its own so the same screen can be bound to
/// anything else.
struct OpenQuickActionsIntent: AppIntent {
    static var title: LocalizedStringResource { "Quick Actions" }
    static var description: IntentDescription {
        IntentDescription("Open PAI's quick actions launcher.")
    }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.receive(.quickActions)
        return .result()
    }
}
