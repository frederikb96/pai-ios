import PAIKit

/// The one way into the MailVerdict assistant. Every surface that offers it — the quick-actions
/// tile today — calls this and nothing else, so the assistant's destination has a single home.
///
/// The assistant has no screen yet: this says so instead of doing nothing, since a tile that
/// swallows a tap reads as broken.
enum MailVerdictAssistantEntry {
    static func open(toasts: ToastCenter) {
        toasts.show("The MailVerdict assistant is not available yet")
    }
}
