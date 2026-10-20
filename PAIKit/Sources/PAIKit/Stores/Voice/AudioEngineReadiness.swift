import Foundation

/// Preconditions `AVAudioEngine` enforces by raising an Objective-C exception rather than
/// throwing a Swift error. Swift cannot catch such an exception, so violating one terminates the
/// app; the app checks them here before calling into the engine.
///
/// Kept free of AVFAudio so the decisions build and test on any platform: the app passes in the
/// engine's own readings as plain values.
public enum AudioEngineReadiness {
    /// Whether a tap or converter may be built on an input reporting this format. With no input
    /// route available (mid route change, during an interruption, in the background without an
    /// active session) the input node reports zero channels or a zero sample rate, and
    /// `installTap(onBus:bufferSize:format:block:)` raises on such a format.
    public static func isUsableInputFormat(sampleRate: Double, channelCount: Int) -> Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }
}

/// Starting the microphone, the way it is allowed to fail: an input can report no usable format
/// for a moment after the session activates or while a route settles, and an engine that sat
/// stopped through another engine's run (a call, wake-word samples) or a route change can keep a
/// stale input that no later start clears. Each failed attempt is followed by a short wait and a
/// recovery step — the caller re-activates its session and builds a fresh engine — before the
/// next attempt, so a start only fails once the budget is spent.
public enum MicrophoneStartRecovery {
    /// Waits before each retry; the whole budget stays under two seconds, short enough that a
    /// tap still feels answered.
    public static let retryDelaysMs = [100, 250, 500, 1000]

    /// `attempt` gets the attempt number from 0; `recover` runs before every retry. The last
    /// error is rethrown once every retry failed. On the main actor, where the audio session and
    /// the engine are driven from.
    @MainActor
    public static func start(
        attempt: (Int) throws -> Void, recover: (Int) -> Void, sleep: (Duration) async -> Void
    ) async throws {
        var index = 0
        while true {
            do {
                try attempt(index)
                return
            } catch {
                guard index < retryDelaysMs.count else { throw error }
                await sleep(.milliseconds(retryDelaysMs[index]))
                index += 1
                recover(index)
            }
        }
    }
}

/// An audio input whose engine can be thrown away for a fresh one — the shape both the
/// dictation capture and the call's bidirectional audio have, so both start through the same
/// recovery.
public protocol RecoverableAudioInput: AnyObject {
    /// One start attempt on the current engine.
    func startOnce() throws
    /// Drops the engine for a fresh one that reads the hardware as it is now.
    func rebuildEngine()
}

extension MicrophoneStartRecovery {
    /// Starts `input`, rebuilding its engine between attempts. `prepareRetry` runs first on every
    /// retry — where a caller re-activates the audio session it owns — and `onFailure` hears
    /// every failed attempt.
    @MainActor
    public static func start(
        _ input: some RecoverableAudioInput, prepareRetry: () throws -> Void = {},
        onFailure: (Int, Error) -> Void = { _, _ in }, sleep: (Duration) async -> Void
    ) async throws {
        try await start(
            attempt: { index in
                do {
                    if index > 0 { try prepareRetry() }
                    try input.startOnce()
                } catch {
                    onFailure(index, error)
                    throw error
                }
            },
            recover: { _ in input.rebuildEngine() }, sleep: sleep)
    }
}
