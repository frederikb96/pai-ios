import PAIKit
import SwiftUI

/// How `TerminalScreen` obtains a live stream connection for a session.
///
/// `PaiTerminalStreamClient` needs a `PaiRequestFactory`, and `AppEnvironment` is the only place
/// that is supposed to own one — the repo's own architecture note is explicit that a second
/// construction site is how the "one request factory owns base URL and auth" guarantee gets
/// lost (`pai-ios/.claude/CLAUDE.md`, "Where the truth lives"). This view has no legitimate way
/// to build a second `PaiRequestFactory` on its own, so the connection is injected through the
/// environment instead of constructed here.
///
/// 🚨 **Not wired yet.** `AppEnvironment.Connection` does not currently expose a
/// `PaiRequestFactory` — it is a local variable inside `AppEnvironment.connect()`, dropped as
/// soon as the REST `PaiApiClient` is built from it. Nothing sets this key today, so
/// `TerminalScreen` shows its "not connected" state until `Connection` grows a
/// `requestFactory: PaiRequestFactory` field (or an equivalent) and whoever wires screens to
/// `AppEnvironment` adds, wherever `TerminalScreen` is pushed:
///
/// ```swift
/// TerminalScreen(sessionID: id)
///     .environment(\.terminalStreamClientFactory) { sessionID, callbacks in
///         PaiTerminalStreamClient(
///             sessionId: sessionID, requestFactory: connection.requestFactory, callbacks: callbacks)
///     }
/// ```
private struct TerminalStreamClientFactoryKey: EnvironmentKey {
    static let defaultValue: ((String, PaiTerminalStreamClient.Callbacks) -> PaiTerminalStreamClient)? =
        nil
}

extension EnvironmentValues {
    var terminalStreamClientFactory: ((String, PaiTerminalStreamClient.Callbacks) -> PaiTerminalStreamClient)?
    {
        get { self[TerminalStreamClientFactoryKey.self] }
        set { self[TerminalStreamClientFactoryKey.self] = newValue }
    }
}
