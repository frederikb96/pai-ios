import Foundation

/// How the Action Button's App Intent reaches live call-mode state without a direct dependency on
/// the app target — the same in-process hand-off `DeepLinkInbox` gives a deep link, for a
/// different shape: the intent needs an answer *now* (is a call running, and did the toggle take
/// effect), not something parked for a screen to pick up later.
///
/// A single registered handler rather than a queue, unlike `DeepLinkInbox`: there is only ever one
/// call running at a time, so there is nothing to park — either the handler is there and the
/// toggle happens synchronously, or it isn't and the intent falls back to its other action (a new
/// session).
@MainActor
public final class VoiceIntentBridge {
    public static let shared = VoiceIntentBridge()

    /// Toggles the running call between recording and wake mode — Freddy's Action Button
    /// replacement for a hardware mute. Returns `true` when a call was actually running to
    /// toggle, `false` when nothing is, so the intent can fall back to its other action.
    /// `nil` until something registers a handler — no call mode has been entered this launch.
    public var toggleCallMode: (() -> Bool)?

    private init() {}
}
