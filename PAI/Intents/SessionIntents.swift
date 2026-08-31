import AppIntents
import Foundation
import PAIKit

/// Writes a launch choice into the shared `DraftKey.newSession` draft ahead of navigating there —
/// the same draft `CreateSessionView` restores from on appear, so a shortcut arrives exactly as
/// if Freddy had tapped the picker himself, and text he was already composing survives it.
///
/// Reads through a standalone client rather than `AppEnvironment.Connection`, the same way
/// ``NoteEntityQuery`` does: an intent can run while the app is not in the foreground yet, before
/// anything holding a live `DraftStore` exists.
enum NewSessionLaunchChoice {
    static func persist(sessionType: String?, workingDir: String?) async {
        guard let client = await AppEnvironment.standaloneClient() else { return }
        let existingText = (try? await client.getDrafts())?.first { $0.key == DraftKey.newSession }?.text ?? ""
        _ = try? await client.putDraft(
            key: DraftKey.newSession, text: existingText, sessionType: sessionType, workingDir: workingDir)
    }
}

/// Start a new **fast** session — vanilla Claude in a sandbox, for a throwaway question.
struct NewFastSessionIntent: AppIntent {
    static var title: LocalizedStringResource { "New Fast Session" }
    static var description: IntentDescription { IntentDescription("Start a new fast session in PAI.") }

    /// Landing on the composer with nothing typed yet is the whole value of this shortcut — it
    /// has to bring the app forward for that to mean anything.
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await NewSessionLaunchChoice.persist(sessionType: "fast", workingDir: nil)
        // Parked rather than navigated directly, for the same reason `OpenNoteIntent` parks its
        // own link: this can run before there is a router to act on it yet.
        DeepLinkInbox.shared.receive(.createSession)
        return .result()
    }
}

/// Start a new **home** session — the ConfigMap-configured default working directory.
struct NewHomeSessionIntent: AppIntent {
    static var title: LocalizedStringResource { "New Home Session" }
    static var description: IntentDescription { IntentDescription("Start a new home session in PAI.") }
    static var openAppWhenRun: Bool { true }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        await NewSessionLaunchChoice.persist(sessionType: "home", workingDir: nil)
        DeepLinkInbox.shared.receive(.createSession)
        return .result()
    }
}

/// Start a new session of a type Freddy configures once, at shortcut-creation time — Shortcuts
/// asks ``SessionTypeEntityQuery`` for the list and remembers the id chosen, the same shape
/// ``OpenNoteIntent`` uses for a single note.
struct NewCustomSessionIntent: AppIntent {
    static var title: LocalizedStringResource { "New Session of Type" }
    static var description: IntentDescription {
        IntentDescription("Start a new session of a chosen type in PAI.")
    }
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Session Type")
    var sessionType: SessionTypeEntity

    init() {}

    init(sessionType: SessionTypeEntity) {
        self.sessionType = sessionType
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        await NewSessionLaunchChoice.persist(sessionType: sessionType.id, workingDir: nil)
        DeepLinkInbox.shared.receive(.createSession)
        return .result()
    }
}

/// A session type, as the Shortcuts app sees it — the launch-type pills `CreateSessionView`
/// shows, minus `fast` and `home`, which already have their own dedicated intents.
struct SessionTypeEntity: AppEntity, Identifiable, Hashable {
    let id: String
    let name: String
    let icon: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Session Type" }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(icon) \(name)")
    }

    static var defaultQuery: SessionTypeEntityQuery { SessionTypeEntityQuery() }

    init(id: String, name: String, icon: String) {
        self.id = id
        self.name = name
        self.icon = icon
    }

    init(_ type: SessionType) {
        self.init(id: type.id, name: type.name, icon: type.icon)
    }
}

struct SessionTypeEntityQuery: EntityQuery, EntityStringQuery {

    func entities(for identifiers: [String]) async throws -> [SessionTypeEntity] {
        let wanted = Set(identifiers)
        return await allTypes().filter { wanted.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [SessionTypeEntity] {
        let needle = string.lowercased()
        guard !needle.isEmpty else { return await allTypes() }
        return await allTypes().filter { $0.name.lowercased().contains(needle) }
    }

    func suggestedEntities() async throws -> [SessionTypeEntity] {
        await allTypes()
    }

    /// The legacy flat `/api/session-types` list — the same fallback `CreateSessionStore` reads
    /// for the default machine, and the only session-type list reachable without a live
    /// `MachineStore`. `fast`/`home` are excluded: they already have their own dedicated
    /// shortcuts, so offering them again here would just be a second way to build the same one.
    private func allTypes() async -> [SessionTypeEntity] {
        guard let client = await AppEnvironment.standaloneClient() else { return [] }
        guard let types = try? await client.getSessionTypes() else { return [] }
        return types.filter { $0.id != "fast" && $0.id != "home" }.map(SessionTypeEntity.init)
    }
}
