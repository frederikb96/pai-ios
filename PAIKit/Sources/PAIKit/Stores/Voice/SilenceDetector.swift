import Foundation

/// Web's "silence detection" gates the audio off once the microphone reads quiet for long
/// enough, then resumes it the moment speech returns, rather than ending the take — a decision
/// made from nothing but a stream of RMS samples over time, which is why it can be exercised
/// here with a synthetic sequence instead of a real microphone.
///
/// Two divergences from `useVoiceRecording.ts`'s `createSilenceTracker`, both deliberate: EMA
/// smoothing on the RMS input, ported from Android's `VoiceTranscriptionService` (the web has
/// none), and the grace period gating when the quiet timer is even allowed to start, matching the
/// web's "arm silence detection after the 3s grace" rather than merely suppressing the fire.
///
/// Android's *other* meaning of "silence detection" — gating the uplink while continuing to
/// record — is now this type's job too, having started as a straight port of the web's older
/// auto-stop semantics; see the block leader's report for why the two converged.
public struct SilenceDetectorConfig: Sendable, Equatable {
    public var enabled: Bool
    public var thresholdRms: Double
    public var durationMs: Int
    /// `SILENCE_GRACE_MS` in the web — mic warm-up must not gate the take.
    public var graceMs: Int
    /// A gate that never lifts must still end the take eventually, or this is an open socket
    /// paying nothing but sitting connected all night. `MAX_CONTINUOUS_SILENCE_MS` in the web —
    /// far longer than `durationMs`'s own default, since this is the backstop for a take nobody
    /// came back to, not the everyday case.
    public var maxGatedMs: Int
    /// Android's EMA weight on the new sample (`0.3*rms + 0.7*smoothed`). `1.0` disables
    /// smoothing and reproduces the web's raw-RMS comparison exactly.
    public var emaAlpha: Double

    public init(
        enabled: Bool,
        thresholdRms: Double,
        durationMs: Int,
        graceMs: Int = 3000,
        maxGatedMs: Int = 120_000,
        emaAlpha: Double = 0.3
    ) {
        self.enabled = enabled
        self.thresholdRms = thresholdRms
        self.durationMs = durationMs
        self.graceMs = graceMs
        self.maxGatedMs = maxGatedMs
        self.emaAlpha = emaAlpha
    }

    public static func from(_ settings: VoiceSettings) -> SilenceDetectorConfig {
        .init(
            enabled: settings.silenceDetectionEnabled,
            thresholdRms: settings.silenceThreshold,
            durationMs: settings.silenceDurationMs
        )
    }
}

/// What the caller should do in response to one `observe` call. `.gate` and `.resume` can each
/// fire any number of times over one take — unlike the auto-stop this type used to drive, a take
/// with two separate pauses gates twice — while `.stop` is the backstop for a gate nobody ever
/// spoke back into, and `VoiceRecordingSession` treats it exactly like `.gate` for the purpose of
/// tearing the gate down before ending the take.
public enum SilenceAction: Sendable, Equatable {
    case none
    case gate
    case resume
    case stop
}

/// A state machine rather than a comparison: the answer depends on when the quiet started, mute
/// has to suspend both clocks without resolving them, and once gated the question flips from "has
/// it been quiet long enough" to "has it been loud again yet, or quiet for so long the take should
/// just end".
public struct SilenceDetector: Sendable {
    private let config: SilenceDetectorConfig
    private var smoothed: Double?
    private var quietSinceMs: Int?
    private var isGated = false
    private var gateStartMs: Int?

    public init(config: SilenceDetectorConfig) {
        self.config = config
    }

    /// - Parameters:
    ///   - rms: this sample's raw amplitude, the same 0...1 scale the web computes from
    ///     `getByteTimeDomainData` (`b/128 - 1`).
    ///   - elapsedMs: milliseconds since the recording started producing audio, on the caller's
    ///     clock — this type never reads a clock itself, so its tests never sleep.
    ///   - muted: a muted mic reads as silence and must never gate or resume from that alone —
    ///     someone who mutes by hand to take a call comes back to a recording still going, with
    ///     silence detection exactly where they left it.
    @discardableResult
    public mutating func observe(rms: Double, elapsedMs: Int, muted: Bool) -> SilenceAction {
        guard config.enabled else { return .none }

        let current = smoothed.map { config.emaAlpha * rms + (1 - config.emaAlpha) * $0 } ?? rms
        smoothed = current

        if isGated {
            // Keeps pushing the backstop's own start forward for as long as the mic stays
            // muted, the same way the pre-gate quiet timer restarts from the unmute rather than
            // resuming a clock that ran the whole time it could not have been listening.
            if muted {
                gateStartMs = elapsedMs
                return .none
            }
            guard current >= config.thresholdRms else {
                // Any sample past the threshold resumes immediately below — no sustained
                // duration required, unlike engaging the gate, so the leading syllable of what
                // comes next is never lost. Until then, only the backstop can end the gate.
                guard let gateStartMs, elapsedMs - gateStartMs >= config.maxGatedMs else {
                    return .none
                }
                isGated = false
                self.gateStartMs = nil
                return .stop
            }
            isGated = false
            gateStartMs = nil
            return .resume
        }

        guard elapsedMs >= config.graceMs, !muted, current < config.thresholdRms else {
            quietSinceMs = nil
            return .none
        }

        let quietStart = quietSinceMs ?? elapsedMs
        quietSinceMs = quietStart
        guard elapsedMs - quietStart >= config.durationMs else { return .none }

        isGated = true
        gateStartMs = elapsedMs
        quietSinceMs = nil
        return .gate
    }
}
