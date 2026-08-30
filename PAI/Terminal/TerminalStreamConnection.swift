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
