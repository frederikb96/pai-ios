import Foundation

/// What claiming the one shared microphone for `sessionID` should do to whatever already holds
/// it, elsewhere or here. Freddy's own rule: "the new one wins, the old one stops cleanly." A
/// pure decision over ids, with no pipeline access of its own, so every branch is provable
/// without a real take running.
public enum VoiceHandoverAction: Equatable, Sendable {
    /// Nothing else is running; just start.
    case startOnly
    /// Whatever is running already belongs to `sessionID` itself — not a handover at all.
    case alreadyHere
    /// A take is running in a different session. Stopping it finalizes its own draft exactly as
    /// an ordinary tap-to-stop would; nothing about the handover changes that.
    case stopMicrophoneTake(sessionID: String)
}

public enum VoiceHandover {
    /// What tapping the composer's mic button in `sessionID` should do. `microphoneTakeSessionID`
    /// is the session a running take is writing into, or `nil` when the microphone is free of one
    /// — never `sessionID` itself, which the composer already handles as an ordinary stop, not a
    /// handover.
    public static func forMicrophoneTap(sessionID: String, microphoneTakeSessionID: String?) -> VoiceHandoverAction {
        guard let running = microphoneTakeSessionID else { return .startOnly }
        return running == sessionID ? .alreadyHere : .stopMicrophoneTake(sessionID: running)
    }
}
