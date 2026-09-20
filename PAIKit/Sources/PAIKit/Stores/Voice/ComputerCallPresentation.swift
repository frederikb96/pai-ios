import Foundation

/// Which of the voice screen's two faces is showing. The call itself decides — a bus the
/// backend switched into a Kai session's call mode reports that on every `state` frame and on
/// `ready`, so this is read, never requested, and switching faces is not navigation.
public enum ComputerCallFace: Equatable, Sendable {
    case computer
    /// `sessionName` is resolved by the client from the session it already lists: `ready`/`state`
    /// carry `session_id` and no title at all (`docs/VOICE_PROTOCOL.md`), so a name is something
    /// this app knows and the wire does not. `nil` while the id names a session this device has
    /// not listed yet.
    case call(sessionId: String, sessionName: String?)
}

/// Everything the voice screen renders, derived in one place from what the socket reports.
///
/// A value rather than a set of computed properties on the view: which face, what the line under
/// it says, and which controls do anything right now are one answer to one question, and three
/// separate derivations of it are three chances for the screen to contradict itself — an End
/// button enabled on a face with nothing to end, a status line naming a session the face does
/// not show.
public struct ComputerCallPresentation: Equatable, Sendable {
    public let face: ComputerCallFace
    /// One short line under the title. Never punctuation-only: something is always said, because
    /// a blank line on a screen showing a live microphone reads as a screen that has stopped
    /// working.
    public let status: String
    /// Which of the call's controls would actually do something if tapped. A control outside this
    /// set is drawn disabled rather than hidden — the row of controls is learnt by position, and
    /// one that moves as the phase changes is one that gets mis-tapped.
    public let enabledCommands: Set<VoiceCallCommand>

    /// The phases `CallModeEngine` reports — `docs/VOICE_PROTOCOL.md`'s wake-word section. Named
    /// here rather than matched inline so the one place that branches on a phase string is the
    /// one place that has to change if the engine gains another.
    public static let recordingPhase = "recording"
    public static let quietPhase = "wake"

    public init(face: ComputerCallFace, status: String, enabledCommands: Set<VoiceCallCommand>) {
        self.face = face
        self.status = status
        self.enabledCommands = enabledCommands
    }

    /// `sessionName` is looked up by the caller from `session_id`, since only the client has it.
    /// `isSpeaking` is the client's own observation that downlink audio is rendering — Computer
    /// announces `listening` once at attach and never says "speaking" itself.
    public static func make(
        connectionState: ComputerCallConnectionState,
        busOwner: VoiceBusOwner,
        phase: String,
        sessionId: String?,
        sessionName: String?,
        isSpeaking: Bool
    ) -> ComputerCallPresentation {
        let face: ComputerCallFace =
            if busOwner == .call, let sessionId {
                .call(sessionId: sessionId, sessionName: sessionName)
            } else {
                .computer
            }

        switch connectionState {
        case .idle:
            return ComputerCallPresentation(face: face, status: "Call ended.", enabledCommands: [])
        case .connecting:
            return ComputerCallPresentation(face: face, status: "Connecting…", enabledCommands: [])
        case .reconnecting:
            // Nothing is enabled while the socket is down: a `command` frame sent into a dead
            // transport is dropped by the session itself, so an enabled control here would be one
            // that silently does nothing at exactly the moment Freddy most wants confirmation.
            return ComputerCallPresentation(face: face, status: "Reconnecting…", enabledCommands: [])
        case .active:
            break
        }

        switch face {
        case .computer:
            return ComputerCallPresentation(
                face: face,
                status: isSpeaking ? "Computer is speaking…" : humanized(phase: phase),
                enabledCommands: []
            )
        case .call:
            return ComputerCallPresentation(
                face: face, status: callStatus(phase: phase, isSpeaking: isSpeaking),
                enabledCommands: commands(inPhase: phase)
            )
        }
    }

    private static func callStatus(phase: String, isSpeaking: Bool) -> String {
        if isSpeaking { return "Speaking the reply…" }
        switch phase {
        case recordingPhase: return "Listening — what you say goes into the draft."
        case quietPhase: return "Quiet. Say “computer”, or tap Start."
        default: return humanized(phase: phase)
        }
    }

    /// `stop` and `send` both end the take that is open, so neither means anything when none is;
    /// `start` opens one, so it means nothing when one already is. Everything else applies in
    /// either phase — a reply is spoken during the quiet phase too, so it can be skipped there,
    /// and leaving for Computer is never phase-dependent.
    ///
    /// Hanging up is deliberately not in here: it is not a frame at all (see `VoiceCallCommand`),
    /// so the End control stays available on every face and in every connection state, including
    /// the one where nothing else is.
    ///
    /// A phase this build does not know is treated as "no take open": the pair that would end one
    /// stays off rather than being offered against a state nothing here can vouch for.
    private static func commands(inPhase phase: String) -> Set<VoiceCallCommand> {
        var enabled: Set<VoiceCallCommand> = [.skip, .listen]
        if phase == recordingPhase {
            enabled.formUnion([.stop, .send])
        } else {
            enabled.insert(.start)
        }
        return enabled
    }

    private static func humanized(phase: String) -> String {
        guard let first = phase.first else { return "…" }
        return "\(first.uppercased())\(phase.dropFirst())…"
    }
}
