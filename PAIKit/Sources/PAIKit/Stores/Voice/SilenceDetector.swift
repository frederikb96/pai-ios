import Foundation

/// Web's "silence detection" auto-STOPS a take once the microphone reads quiet for long enough —
/// a decision made from nothing but a stream of RMS samples over time, which is why it can be
/// exercised here with a synthetic sequence instead of a real microphone.
///
/// Two divergences from `useVoiceRecording.ts`'s `createSilenceTracker`, both deliberate: EMA
/// smoothing on the RMS input, ported from Android's `VoiceTranscriptionService` (the web has
/// none), and the grace period gating when the quiet timer is even allowed to start, matching the
/// web's "arm silence detection after the 3s grace" rather than merely suppressing the fire.
///
/// Android's *other* meaning of "silence detection" — gating the uplink while continuing to
/// record — is not this type's job. This ports the web's semantics, which is what Freddy's
/// current daily driver contract is; see the block leader's report for the divergence.
public struct SilenceDetectorConfig: Sendable, Equatable {
    public var enabled: Bool
    public var thresholdRms: Double
    public var durationMs: Int
    /// `SILENCE_GRACE_MS` in the web — mic warm-up must not auto-stop the take.
    public var graceMs: Int
    /// Android's EMA weight on the new sample (`0.3*rms + 0.7*smoothed`). `1.0` disables
    /// smoothing and reproduces the web's raw-RMS comparison exactly.
    public var emaAlpha: Double

    public init(
        enabled: Bool,
        thresholdRms: Double,
        durationMs: Int,
        graceMs: Int = 3000,
        emaAlpha: Double = 0.3
    ) {
        self.enabled = enabled
        self.thresholdRms = thresholdRms
        self.durationMs = durationMs
        self.graceMs = graceMs
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

/// Fires once, the moment smoothed RMS has stayed below threshold for `durationMs` past the
/// grace period. Never fires twice for the same take — `observe` returns `true` exactly once, so
/// a caller driving a stop action from it cannot double-stop.
public struct SilenceDetector: Sendable {
    private let config: SilenceDetectorConfig
    private var smoothed: Double?
    private var quietSinceMs: Int?
    private var fired = false

    public init(config: SilenceDetectorConfig) {
        self.config = config
    }

    /// - Parameters:
    ///   - rms: this sample's raw amplitude, the same 0...1 scale the web computes from
    ///     `getByteTimeDomainData` (`b/128 - 1`).
    ///   - elapsedMs: milliseconds since the recording started producing audio, on the caller's
    ///     clock — this type never reads a clock itself, so its tests never sleep.
    ///   - muted: a muted mic reads as silence and must never end a recording.
    /// - Returns: `true` the one time this call crosses the silence threshold.
    @discardableResult
    public mutating func observe(rms: Double, elapsedMs: Int, muted: Bool) -> Bool {
        guard config.enabled, !fired else { return false }

        let current = smoothed.map { config.emaAlpha * rms + (1 - config.emaAlpha) * $0 } ?? rms
        smoothed = current

        guard elapsedMs >= config.graceMs, !muted, current < config.thresholdRms else {
            quietSinceMs = nil
            return false
        }

        let quietStart = quietSinceMs ?? elapsedMs
        quietSinceMs = quietStart
        guard elapsedMs - quietStart >= config.durationMs else { return false }

        fired = true
        return true
    }
}
