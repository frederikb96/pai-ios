import AppIntents
import Foundation
import PAIKit

/// Open the note index.
struct OpenNotesIntent: AppIntent {
    static var title: LocalizedStringResource { "Open Notes" }
    static var description: IntentDescription { IntentDescription("Open the note list in PAI.") }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkInbox.shared.receive(.notesList)
        return .result()
    }
}

/// Create a new note and open it — the shortcut equivalent of the note list's own plus button.
///
/// Creates through a standalone client rather than waiting for the app's own `NotesStore`, the
/// same reason ``NewSessionLaunchChoice`` does: a shortcut runs before anything holding a live
/// store necessarily exists. A name already taken is numbered by the server, so a shortcut fired
/// twice in a row lands on `date` and `date 2`.
struct CreateNoteIntent: AppIntent {
    static var title: LocalizedStringResource { "New Note" }
    static var description: IntentDescription { IntentDescription("Create a new note in PAI.") }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let client = await AppEnvironment.standaloneClient() else {
            throw CreateNoteIntentError.notSignedIn
        }
        guard let created = try? await client.createNote(name: NoteNaming.todayName()) else {
            throw CreateNoteIntentError.createFailed
        }
        // Same one-shot signal the note list's own "+" button sends — see
        // `NoteCreationFocus`'s doc comment. A note created by a shortcut deserves the same
        // focused title, caret at the end, as one created by tapping the button in-app.
        NoteCreationFocus.shared.markCreated(id: created.id)
        DeepLinkInbox.shared.receive(.note(id: created.id))
        return .result()
    }
}

enum CreateNoteIntentError: Swift.Error, CustomLocalizedStringResourceConvertible {
    case notSignedIn
    case createFailed

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notSignedIn: return "Sign in to PAI before creating a note this way."
        case .createFailed: return "Could not create the note."
        }
    }
}
