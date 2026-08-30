import PAIKit
import UserNotifications

/// A time-sensitive local notification for the one thing worth telling Freddy about while he
/// isn't looking: a take the app was alive to see end for a reason he didn't choose.
///
/// This is a nicety layered on top of the durability work, never a substitute for it — it only
/// fires if the process survives long enough to fire it, and the physical mute switch can silence
/// it outright even then. The recording itself has to survive on its own; this can only report.
///
/// Owns no authorization request of its own — `PushRegistrar`/`PushRegistrationStore` is the
/// single claimant of the one-shot system prompt, so asking here as well would either spend it on
/// a moment the recording flow does not need answered, or silently re-ask and get back whatever
/// that first prompt decided with no way to tell the difference.
enum VoiceInterruptionNotifier {
    /// `reason` is expected to be one the app was alive to *observe* going wrong — an
    /// interruption that could not resume, a reconnect that exhausted its attempts, or a protocol
    /// error. `VoiceRecorderController` is what decides which reasons qualify; this only renders
    /// whichever one it is given, and only once notifications are actually authorised — silently
    /// no-op otherwise rather than posting a request nothing will ever show.
    static func notify(reason: RecordingEndReason) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Voice recording stopped"
        content.body = body(for: reason)
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        // Swallowed rather than surfaced: this whole facility is the nicety that tells him a take
        // broke, and a take that broke is already the bad news. Failing to deliver that notice is
        // not worth a second failure path in the caller.
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func body(for reason: RecordingEndReason) -> String {
        switch reason {
        case .interrupted: "It could not resume after an interruption — a call, most likely."
        case .connectionLost: "It lost its connection and could not reconnect."
        case .error: "It stopped because of a server error."
        case .user, .silence: "It stopped."
        }
    }
}
