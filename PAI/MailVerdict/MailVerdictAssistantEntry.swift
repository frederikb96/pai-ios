import PAIKit

/// The one way into the MailVerdict assistant. Every surface that offers it — the quick-actions
/// tile today — calls this and nothing else, so the assistant's destination has a single home.
///
/// The assistant is a session of type `mailverdict`, so opening it is opening the new-session
/// screen with that type chosen. The backend reaches MailVerdict with the caller's own sign-in, so
/// the phone sends nothing extra.
@MainActor
enum MailVerdictAssistantEntry {
    static func open(environment: AppEnvironment, drafts: DraftStore) {
        NewSessionLaunch.start(
            type: CreateSessionStore.mailverdictSessionTypeId, environment: environment, drafts: drafts)
    }
}
