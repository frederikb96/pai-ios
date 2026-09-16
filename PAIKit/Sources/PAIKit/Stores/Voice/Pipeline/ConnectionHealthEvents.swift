import Foundation

/// What `ConnectionHealth` reacts to — pure inputs, no I/O of its own. The app feeds
/// `pathSatisfied` from `NWPathMonitor`; everything else comes from `VoiceRecordingSession`'s own
/// realtime socket and token mint.
public enum ConnectionHealthEvent: Sendable, Equatable {
    case pathSatisfied(Bool)
    case socketOpened
    case socketDelivered
    case socketClosed(reason: String?)
    case mintFailed
    case mintSucceeded
    case tick(Date)
}

/// `ConnectionHealth`'s state. `stable` is the gate every backfill request and reserve-token mint
/// waits on; the thresholds that produce it are `ConnectionHealth`'s own constants, not this
/// type's concern.
public enum HealthState: String, Sendable, Equatable {
    case offline, connecting, unstable, stable
}
