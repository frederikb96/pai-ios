import Foundation

/// The preconditions `AVAudioEngine` enforces by raising an Objective-C exception rather than
/// throwing a Swift error. Swift cannot catch such an exception, so violating one terminates the
/// app; every call into the engine that has one is checked here first instead.
///
/// Kept free of AVFAudio so the decisions build and test on any platform: the app passes in the
/// engine's own readings and actions as closures and values.
public enum AudioEngineReadiness {
    /// Starts the engine when it is not running and reports whether it is running afterwards —
    /// the precondition of `AVAudioPlayerNode.play()`, which raises when its engine is stopped.
    ///
    /// A start can fail in ordinary use: the app is in the background with its audio session
    /// already deactivated (a cue sounding after a take ended, once a delayed backfill completes),
    /// or a configuration change has just stopped the engine underneath a running take. A failed
    /// start is reported to `onStartFailure` and answers `false`; the caller then skips whatever
    /// needed a running engine. Running is re-read after a start that did not throw, rather than
    /// assumed from it.
    public static func ensureRunning(
        isRunning: () -> Bool, start: () throws -> Void, onStartFailure: (any Error) -> Void = { _ in }
    ) -> Bool {
        if isRunning() { return true }
        do {
            try start()
        } catch {
            onStartFailure(error)
            return false
        }
        return isRunning()
    }

    /// Whether a tap or converter may be built on an input reporting this format. With no input
    /// route available (mid route change, during an interruption, in the background without an
    /// active session) the input node reports zero channels or a zero sample rate, and
    /// `installTap(onBus:bufferSize:format:block:)` raises on such a format.
    public static func isUsableInputFormat(sampleRate: Double, channelCount: Int) -> Bool {
        sampleRate > 0 && sampleRate.isFinite && channelCount > 0
    }
}
