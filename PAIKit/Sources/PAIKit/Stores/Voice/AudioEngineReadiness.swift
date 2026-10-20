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
