import Foundation

/// Canned JSON matching the PAI Cloud API contract (`pai-cloud/web/src/api/types.ts`,
/// `client.ts`, and the behaviour documented in `pai-cloud/docs/ARCHITECTURE.md`) — for driving
/// the app with no backend anywhere, and for proving these bytes actually decode.
///
/// Every fixture is a Swift string literal, never a bundled resource. `Bundle.module` resolves
/// differently between `swift test`, an app target vendoring this package locally, and a CI
/// runner that never went through Xcode — three lookup paths for one file, and getting any of
/// them wrong fails at runtime rather than at compile time, on whichever host didn't get
/// exercised while writing it. A string constant has exactly one lookup path: it exists the
/// moment the module loads, identically in a test, in the app, and in a screenshot workflow.
///
/// Fixtures are grouped by response shape, one file per area:
/// - `PaiFixtures+Sessions.swift` — machines, session types, health, identity, the session list
///   (both machines, every `SessionState`, every `BlockerKind`, a subagent), semantic search
/// - `PaiFixtures+Transcript.swift` — one session's full transcript: every `Message` type and
///   system subtype, every tool family, and the markdown edge cases that stress the renderer
/// - `PaiFixtures+Voice.swift` — drafts, plan usage, secret presence, a voice token, Claude
///   sign-in state, and the recording metadata a "past recordings" screen would show
/// - `PaiFixtures+Terminal.swift` — a short terminal frame sequence, live and scrolled-back
/// - `PaiFixtures+Outgoing.swift` — request bodies the app itself sends, so a control that
///   renders correctly and puts the wrong thing on the wire has something to be caught against
/// - `PaiFixtures+Unhappy.swift` — error bodies, empty pages, and the minimal/discovered session
///
/// Nothing here references a model type from `Models/` — those are mid-rewrite against the same
/// contract this mirrors, and a fixture that imported them would break every time either side
/// moved, for no reason connected to whether the JSON itself is right. Nothing decodes into a
/// concrete type either; see `PAIKitTests/PaiFixturesTests.swift` for why that is a deliberate,
/// temporary gap and not an oversight.
public enum PaiFixtures {
    /// UTF-8 bytes of a fixture string, ready for `JSONDecoder` or a stubbed `URLProtocol`.
    public static func data(_ json: String) -> Data {
        Data(json.utf8)
    }
}
