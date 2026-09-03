import Observation

#if DEBUG
    import Foundation
#endif

/// A destination the app can navigate to.
///
/// `NavigationStack` accepts a plain array binding, so routing needs no SwiftUI and lives here
/// rather than in the app target — which means it is covered by the package's tests instead of
/// waiting on an Apple runner.
///
/// Routes carry identifiers rather than models. A `Session` fetched when a row was tapped is
/// stale by the time the screen it opened is still on top of the stack, and a path restored
/// after a relaunch has no models to carry at all.
public enum Route: Hashable, Sendable {
    /// `messageID` is where to jump once the transcript is open, never part of the route's
    /// identity — two pushes of the same session that differ only in where they jump to are the
    /// same screen, so equality and hashing below ignore it deliberately. Nil for an ordinary
    /// open; set when arrived at from a notification (row 5.28).
    case session(id: String, messageID: Int? = nil)
    case terminal(sessionID: String)
    case settings
    /// Reached only from the fixture screenshot workflow — real usage never pushes this, it
    /// presents `CreateSessionView` as a sheet from the session list. `RootView` answers this
    /// route by reproducing that exact presentation (a sheet over a blank screen) rather than
    /// pushing the view directly, so what gets photographed is what Freddy actually sees, not a
    /// second `NavigationStack` nested inside the first with its own, different chrome.
    case createSession
    /// One conversation's own subagents — reached from its actions menu, never from a subagent
    /// itself (a subagent's own children are flattened into its top-level parent, so it has
    /// nothing of its own to show here).
    case subagents(parentID: String)
    /// The note index.
    case notes
    /// One note's editor. Reached from the index, from a wikilink in another note, and from a
    /// home-screen shortcut — which is why it carries only an id: a shortcut is configured once
    /// and opened months later, so anything richer would be stale by the time it is used.
    case note(id: String)
    /// The note containers screen — which directories on which machines are synced.
    case noteContainers
    /// The same note, opened on its rendered page rather than its source. Reached by tapping a
    /// wikilink inside another note's own rendered page (``NoteBodyView``) — staying in preview
    /// there is the point, since reading is what that tap was doing — and by the fixture
    /// screenshot workflow, for the same reason it always has been: the preview is otherwise only
    /// a toggle inside the editor, and it is the screen whose *rendering* most needs photographing.
    case notePreview(id: String)
    /// The notification centre (row 5.27) — every alert transition and every agent push, as a
    /// persistent, filterable log.
    case notifications
    /// Past Recordings. Reached only from the fixture screenshot workflow, the same way
    /// `.createSession` is: real usage presents `RecordingsSheet` from the composer's plus-icon,
    /// never by pushing a route, so `RootView` reproduces that sheet presentation here rather
    /// than pushing the view directly. Without this the picker's "Recovered" row is never drawn
    /// anywhere free — no route means the screenshot workflow can never reach it at all,
    /// regardless of whether the list underneath has anything in it.
    case recordings
    /// One spec's timeline — reached from a session's "Spec" action, never a home-screen
    /// shortcut or a notification, so unlike `.note`/`.session` it carries no separate identity
    /// concern: nothing ever replaces one `.arcSpec` destination with a different one at the
    /// same stack depth.
    case arcSpec(specUuid: String)

    /// Ignores `session`'s `messageID` — see that case's doc comment. Everything else is a plain
    /// per-case comparison, same as the synthesized version this replaces.
    public static func == (lhs: Route, rhs: Route) -> Bool {
        switch (lhs, rhs) {
        case (.session(let a, _), .session(let b, _)): return a == b
        case (.terminal(let a), .terminal(let b)): return a == b
        case (.settings, .settings): return true
        case (.createSession, .createSession): return true
        case (.subagents(let a), .subagents(let b)): return a == b
        case (.notes, .notes): return true
        case (.note(let a), .note(let b)): return a == b
        case (.noteContainers, .noteContainers): return true
        case (.notePreview(let a), .notePreview(let b)): return a == b
        case (.notifications, .notifications): return true
        case (.recordings, .recordings): return true
        case (.arcSpec(let a), .arcSpec(let b)): return a == b
        default: return false
        }
    }

    /// Kept consistent with the custom `==` above by construction — hashing the same fields it
    /// compares, and nothing else, is what keeps the Hashable contract from breaking silently.
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .session(let id, _):
            hasher.combine(0)
            hasher.combine(id)
        case .terminal(let sessionID):
            hasher.combine(1)
            hasher.combine(sessionID)
        case .settings:
            hasher.combine(2)
        case .createSession:
            hasher.combine(3)
        case .subagents(let parentID):
            hasher.combine(4)
            hasher.combine(parentID)
        case .notes:
            hasher.combine(5)
        case .note(let id):
            hasher.combine(6)
            hasher.combine(id)
        case .noteContainers:
            hasher.combine(7)
        case .notePreview(let id):
            hasher.combine(8)
            hasher.combine(id)
        case .notifications:
            hasher.combine(9)
        case .recordings:
            hasher.combine(10)
        case .arcSpec(let specUuid):
            hasher.combine(11)
            hasher.combine(specUuid)
        }
    }
}

extension Route {
    /// Every screen name the fixture screenshot workflow can launch straight into.
    ///
    /// The root session list is not listed here — it needs no route, since it is what
    /// `RootView` shows for an empty navigation path, and the workflow always photographs it
    /// first regardless. Extend this array and `named(_:sessionID:)` together whenever `Route`
    /// gains a case; the workflow itself asks the running app for this list rather than
    /// hardcoding it, so a new screen becomes photographable without a CI file edit.
    public static let namedScreens: [String] = [
        "session", "terminal", "settings", "createSession", "subagents", "notes", "note", "noteContainers",
        "notePreview", "notifications", "recordings", "arcSpec",
    ]

    /// Every spec-scoped fixture route answers under, regardless of which uuid the request
    /// actually named — the same fixed-id pattern `fixtureNoteID` uses, so the screenshot
    /// workflow can ask for the ARC screen without first discovering a real spec exists.
    public static let fixtureArcSpecUuid = "3f1c9d7a-4b8e-4a2f-9c1d-7e5a2b6f0d31"

    /// Parses a launch-argument screen name into a route. `sessionID` fills in every
    /// session-scoped case — the fixture corpus answers identically for any id, so the caller
    /// need not know which one fixture mode picked. `noteID` does the same for the note cases.
    /// The note id every note-scoped fixture route answers under, regardless of which id the
    /// request actually named — fixed for the same reason `PaiFixtureLaunch.sessionID` is, so the
    /// screenshot workflow can ask for a note without first discovering which one exists.
    public static let fixtureNoteID = "6a0b5f2e-9d47-4c1a-8f30-2b7e5c918d64"

    public static func named(
        _ name: String, sessionID: String, noteID: String = Route.fixtureNoteID
    ) -> Route? {
        switch name {
        case "session": return .session(id: sessionID)
        case "terminal": return .terminal(sessionID: sessionID)
        case "settings": return .settings
        case "createSession": return .createSession
        case "subagents": return .subagents(parentID: sessionID)
        case "notes": return .notes
        case "note": return .note(id: noteID)
        case "noteContainers": return .noteContainers
        case "notePreview": return .notePreview(id: noteID)
        case "notifications": return .notifications
        case "recordings": return .recordings
        case "arcSpec": return .arcSpec(specUuid: fixtureArcSpecUuid)
        default: return nil
        }
    }
}

/// What the app shows instead of the navigation stack.
///
/// These are mutually exclusive whole-screen states, so they are one value rather than a set of
/// booleans that can contradict each other. `unreachable` is deliberately absent: a backend that
/// cannot be reached is a banner over whatever is already on screen, not a screen of its own —
/// the sessions loaded a moment ago are still worth reading.
public enum AppGate: Equatable, Sendable {
    /// No backend URL or no token yet — first launch, or after a reset.
    case needsConfiguration
    /// A token exists and the backend rejected it. Distinct from `needsConfiguration` because the
    /// recovery is different: the URL is known and probably right, and only the token needs
    /// replacing. Without the distinction there is no way back from a revoked token.
    case tokenRejected
    case ready
}

extension Route {
    /// What the path should become after an interactive pop (the back gesture, the back button,
    /// or a long-press jump to an ancestor) — corrected so leaving the sub-agent screens always
    /// lands on the parent session's transcript, never on whatever the reader would otherwise
    /// land on.
    ///
    /// `NavigationStack`'s own pop is right on its own for the ordinary case — a sub-agent's own
    /// transcript back to the sub-agent list — but `.subagents(parentID:)` can be reached
    /// directly from the session list (`SessionActionsSheet`, opened from either screen), with no
    /// parent transcript underneath it on the stack. Popping *that* screen then lands on the
    /// session list rather than on the session its sub-agents belong to. Triggers on the
    /// `.subagents` route leaving the path entirely — a single swipe back out of it, or a
    /// long-press jump straight past it to an ancestor — never on navigating merely within it.
    public static func pathAfterLeavingSubagents(from oldPath: [Route], to newPath: [Route]) -> [Route] {
        guard let parentID = oldPath.subagentsParentID, newPath.subagentsParentID == nil else { return newPath }
        guard newPath.last != .session(id: parentID) else { return newPath }
        return newPath + [.session(id: parentID)]
    }
}

extension [Route] {
    fileprivate var subagentsParentID: String? {
        for route in self {
            if case .subagents(let id) = route { return id }
        }
        return nil
    }
}

/// The navigation path, and the gate in front of it.
///
/// Kept as a value-holding observable rather than free functions on the view so that "where is
/// the user" is a question with one answer, and so a deep link and a tap take the same path.
@Observable
public final class Router {
    public private(set) var path: [Route] = []
    public var gate: AppGate

    public init(gate: AppGate = .needsConfiguration) {
        self.gate = gate
        #if DEBUG
            // The one hook the fixture screenshot workflow needs into navigation: seed the
            // initial path from a launch argument, entirely inside the type that already owns
            // `path`, so no caller of `Router.init` has to know fixture mode exists.
            self.path = Router.fixtureInitialPath()
        #endif
    }

    #if DEBUG
        /// Split out of `init` so a test can inject an argument array instead of depending on the
        /// live process's own — the process running the test suite never carries
        /// `-PaiFixtureMode`, so `init` alone would never exercise this branch.
        static func fixtureInitialPath(arguments: [String] = ProcessInfo.processInfo.arguments) -> [Route] {
            guard PaiFixtureLaunch.isEnabled(arguments: arguments),
                let name = PaiFixtureLaunch.requestedRouteName(arguments: arguments),
                let route = Route.named(name, sessionID: PaiFixtureLaunch.sessionID)
            else { return [] }
            return [route]
        }
    #endif

    public func push(_ route: Route) {
        path.append(route)
    }

    public func pop() {
        guard !path.isEmpty else { return }
        path.removeLast()
    }

    public func popToRoot() {
        path.removeAll()
    }

    /// Leave a session's screens entirely — its transcript and anything pushed on top of it,
    /// such as its own terminal.
    ///
    /// Exists because a plain `pop()` is wrong for the case that needs this: a screen reacting to
    /// its own session ceasing to exist, which can happen while the reader has navigated deeper.
    /// Popping one route would close the terminal and leave the dead transcript underneath — a
    /// screen about a session that is gone, still accepting input.
    ///
    /// Drops from the *first* matching route so a session opened twice in one path is left
    /// nowhere, and does nothing at all when the path does not contain it.
    public func dismissSession(id: String) {
        guard let index = path.firstIndex(of: .session(id: id)) else { return }
        path.removeSubrange(index...)
    }

    /// Leave a note's editor, from the editor itself — after deleting the note it was showing.
    ///
    /// A plain `pop()` is wrong for that: the delete can be confirmed from a sheet presented over
    /// the editor, and by the time it succeeds the reader may have navigated on. Dropping from the
    /// first matching route leaves a note opened twice in one path nowhere, and does nothing when
    /// the path does not contain it.
    public func dismissNote(id: String) {
        guard let index = path.firstIndex(of: .note(id: id)) else { return }
        path.removeSubrange(index...)
    }

    /// Replace the whole path, for a deep link or a restored session.
    public func replace(with routes: [Route]) {
        path = routes
    }

    /// The session whose transcript is on screen, if one is.
    ///
    /// Read from the top of the path rather than tracked separately: two records of the same fact
    /// diverge, and the one not driving the screen is the one that goes wrong silently.
    public var openSessionID: String? {
        for route in path.reversed() {
            switch route {
            case .session(let id, _): return id
            case .terminal(let sessionID): return sessionID
            case .settings, .createSession, .subagents, .notes, .note, .noteContainers, .notePreview,
                .notifications, .recordings, .arcSpec:
                continue
            }
        }
        return nil
    }

    /// The note whose editor is on screen, if one is. Read from the path for the same reason
    /// `openSessionID` is — a second record of the same fact is the one that goes wrong quietly.
    public var openNoteID: String? {
        for route in path.reversed() {
            switch route {
            case .note(let id), .notePreview(let id): return id
            case .session, .terminal, .settings, .createSession, .subagents, .notes, .noteContainers,
                .notifications, .recordings, .arcSpec:
                continue
            }
        }
        return nil
    }

    /// Open a note from outside the navigation stack — a home-screen shortcut, or a notification.
    ///
    /// Replaces the path rather than pushing onto it: a deep link arrives with no knowledge of
    /// what the app was showing, and pushing would bury the note under whatever the reader had
    /// left open. The note index sits underneath so Back has somewhere to go, which is what
    /// arriving from the app itself would have produced.
    public func openNote(id: String) {
        replace(with: [.notes, .note(id: id)])
    }

    /// Open a session from outside the navigation stack — a tapped notification.
    public func openSession(id: String) {
        replace(with: [.session(id: id)])
    }

    /// Send the user back to token entry, keeping the backend URL.
    ///
    /// Clears the path as well as the gate: leaving a transcript underneath means it reappears
    /// showing whatever it held before the token stopped working.
    public func rejectToken() {
        path.removeAll()
        gate = .tokenRejected
    }
}
