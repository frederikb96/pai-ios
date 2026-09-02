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
    case session(id: String)
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
    /// The same note, opened on its rendered page rather than its source. Reached only from the
    /// fixture screenshot workflow: the preview is a toggle inside the editor and nothing else
    /// navigates to it, but it is the screen whose *rendering* most needs photographing, and
    /// nothing free can see it.
    case notePreview(id: String)
    /// Past Recordings. Reached only from the fixture screenshot workflow, the same way
    /// `.createSession` is: real usage presents `RecordingsSheet` from the composer's plus-icon,
    /// never by pushing a route, so `RootView` reproduces that sheet presentation here rather
    /// than pushing the view directly. Without this the picker's "Recovered" row is never drawn
    /// anywhere free — no route means the screenshot workflow can never reach it at all,
    /// regardless of whether the list underneath has anything in it.
    case recordings
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
        "notePreview", "recordings",
    ]

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
        case "recordings": return .recordings
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
            case .session(let id): return id
            case .terminal(let sessionID): return sessionID
            case .settings, .createSession, .subagents, .notes, .note, .noteContainers, .notePreview, .recordings:
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
            case .session, .terminal, .settings, .createSession, .subagents, .notes, .noteContainers, .recordings:
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
