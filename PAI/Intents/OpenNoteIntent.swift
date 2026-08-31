import AppIntents
import Foundation
import PAIKit

/// Open one note's editor.
///
/// This is what makes a home-screen shortcut per note possible: Shortcuts offers this action,
/// the note picker comes from ``NoteEntityQuery``, and "Add to Home Screen" turns the result into
/// an icon Freddy names himself. Nothing here is TestFlight-specific — App Intents are part of
/// the app bundle, so a TestFlight build exposes them exactly as an App Store one would.
struct OpenNoteIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Note" }
    static var description: IntentDescription { IntentDescription("Open a note in PAI.") }

    /// The app has to come to the front — the whole action is "put me in this note". Without it
    /// the intent would succeed silently while nothing appeared.
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Note")
    var note: NoteEntity

    init() {}

    init(note: NoteEntity) {
        self.note = note
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        // Parked rather than navigated, for the same reason a tapped notification is: this runs
        // before the app is necessarily awake, so there may be no router yet. `RootView` picks it
        // up as soon as there is somewhere to put it.
        DeepLinkInbox.shared.receive(.note(id: note.id))
        return .result()
    }
}

/// Open a session's transcript.
///
/// The session equivalent, so a shortcut or an automation can land on a running conversation.
/// Takes a plain id rather than an entity: sessions are numerous, short-lived and titled by a
/// summariser, so a picker over them would offer a list that is mostly stale by the time anyone
/// scrolls it — while the id is what a notification and an automation already carry.
struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Session" }
    static var description: IntentDescription { IntentDescription("Open a PAI session by its id.") }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Session ID")
    var sessionID: String

    init() {}

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.receive(.session(id: sessionID))
        return .result()
    }
}

/// The phrases Siri and Spotlight accept without Freddy building a shortcut first.
///
/// Every phrase has to contain `\(.applicationName)`; a phrase without it is rejected at build
/// time on Apple hardware and nowhere else, which is a long way to travel for a typo.
struct PaiAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNoteIntent(),
            phrases: [
                "Open a note in \(.applicationName)",
                "Open \(.applicationName) note",
            ],
            shortTitle: "Open Note",
            systemImageName: "note.text"
        )
        AppShortcut(
            intent: OpenNotesIntent(),
            phrases: [
                "Open notes in \(.applicationName)",
                "Open \(.applicationName) notes",
            ],
            shortTitle: "Notes",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: CreateNoteIntent(),
            phrases: [
                "Create a note in \(.applicationName)",
                "New \(.applicationName) note",
            ],
            shortTitle: "New Note",
            systemImageName: "square.and.pencil"
        )
        AppShortcut(
            intent: NewFastSessionIntent(),
            phrases: [
                "Start a fast session in \(.applicationName)",
                "New \(.applicationName) fast session",
            ],
            shortTitle: "New Fast Session",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: NewHomeSessionIntent(),
            phrases: [
                "Start a home session in \(.applicationName)",
                "New \(.applicationName) home session",
            ],
            shortTitle: "New Home Session",
            systemImageName: "message.fill"
        )
        AppShortcut(
            intent: NewCustomSessionIntent(),
            phrases: [
                "Start a \(\.$sessionType) session in \(.applicationName)",
                "New \(.applicationName) session",
            ],
            shortTitle: "New Session of Type",
            systemImageName: "rectangle.stack.badge.plus"
        )
    }
}
