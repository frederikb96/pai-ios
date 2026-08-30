import PAIKit
import UserNotifications

/// A time-sensitive local notification for the one thing worth telling Freddy about while he
/// isn't looking: a take the app was alive to see end for a reason he didn't choose.
///
/// This is a nicety layered on top of the durability work, never a substitute for it — it only
/// fires if the process survives long enough to fire it, and the physical mute switch can silence
/// it outright even then. The recording itself has to survive on its own; this can only report.
enum VoiceInterruptionNotifier {
    /// Idempotent past the first answer — safe to call before every take rather than tracking
    /// whether it was already asked. Called from `start()`, alongside the microphone permission
    /// request it already makes there.
    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `reason` is expected to be one the app was alive to *observe* going wrong — an
    /// interruption that could not resume, a reconnect that exhausted its attempts, or a protocol
    /// error. `VoiceRecorderController` is what decides which reasons qualify; this only renders
    /// whichever one it is given.
    static func notify(reason: RecordingEndReason) {
        let content = UNMutableNotificationContent()
        content.title = "Voice recording stopped"
        content.body = body(for: reason)
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
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
