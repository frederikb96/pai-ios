import Foundation

/// What the composer's plus menu offers for call mode in one session, given which session (if
/// any) a running call is bound to. A pure read of two ids — no pipeline state, no view state —
/// so the menu's own three-way branch is provable without a call, a controller or a screen.
public enum ComposerCallMenuState: Equatable, Sendable {
    /// No call is running anywhere; the menu offers to start one here.
    case start
    /// The call running is this session's own; the menu offers to return to its screen, and to
    /// end it.
    case returnToCall
    /// A call is running in a different session; the menu offers to stop it and start here.
    case runningElsewhere
}

public enum ComposerCallMenu {
    public static func state(callBoundSessionID: String?, sessionID: String) -> ComposerCallMenuState {
        guard let bound = callBoundSessionID else { return .start }
        return bound == sessionID ? .returnToCall : .runningElsewhere
    }
}

/// What claiming the one shared microphone for `sessionID` should do to whatever already holds
/// it — a microphone-mode take, or call mode — elsewhere or here. Freddy's own rule: "the new one
/// wins, the old one stops cleanly." A pure decision over ids and a flag, with no pipeline access
/// of its own, so every branch is provable without a real take or a real call running.
public enum VoiceHandoverAction: Equatable, Sendable {
    /// Nothing else is running; just start.
    case startOnly
    /// Whatever is running already belongs to `sessionID` itself — not a handover at all.
    case alreadyHere
    /// A microphone-mode take is running in a different session. Stopping it finalizes its own
    /// draft exactly as an ordinary tap-to-stop would; nothing about the handover changes that.
    case stopMicrophoneTake(sessionID: String)
    /// Call mode is running — bound to this session or another — and must be ended cleanly before
    /// the new claim can start.
    case stopCallMode
}

public enum VoiceHandover {
    /// What tapping the composer's mic button in `sessionID` should do. `microphoneTakeSessionID`
    /// is the session a running take is writing into, or `nil` when the microphone is free of one
    /// — never `sessionID` itself, which the composer already handles as an ordinary stop, not a
    /// handover.
    public static func forMicrophoneTap(
        sessionID: String, microphoneTakeSessionID: String?, callModeActive: Bool
    ) -> VoiceHandoverAction {
        if callModeActive { return .stopCallMode }
        guard let running = microphoneTakeSessionID else { return .startOnly }
        return running == sessionID ? .alreadyHere : .stopMicrophoneTake(sessionID: running)
    }

    /// What choosing "start call mode" for `sessionID` should do — from the plus menu's own
    /// `.start`/`.returnToCall`/`.runningElsewhere` entry alike, so the same decision drives
    /// every one of them.
    public static func forCallModeStart(
        sessionID: String, callBoundSessionID: String?, microphoneTakeSessionID: String?
    ) -> VoiceHandoverAction {
        if let bound = callBoundSessionID {
            return bound == sessionID ? .alreadyHere : .stopCallMode
        }
        guard let running = microphoneTakeSessionID else { return .startOnly }
        return .stopMicrophoneTake(sessionID: running)
    }
}
