import Foundation

/// Pure math around the sample rate sent to ElevenLabs — no capture, no resampling, just the two
/// rules `transportRate()` (`web/src/utils/audio.ts`) encodes: never invent samples by raising
/// the rate, and never spend bandwidth above what the recognition model uses.
///
/// Actual resampling is not this type's job, or this package's: the app's `AVAudioConverter`
/// does it. Hand-rolling interpolation here would reproduce exactly the per-chunk-discontinuity
/// bug the web's filtered resampler exists to avoid — see the block leader's report, §4.
public enum VoiceAudioRatePolicy {
    /// `SUPPORTED_PCM_RATES` — every rate ElevenLabs' realtime endpoint accepts, ascending.
    public static let supportedRates = [8000, 16000, 22050, 24000, 44100, 48000]

    /// Recognition uses nothing above 24 kHz, so nothing above it is ever requested; below that,
    /// the hardware rate is used as-is rather than upsampled, snapped down to the nearest rate
    /// ElevenLabs accepts.
    public static func transportRate(hardwareRate: Int) -> Int {
        let capped = min(hardwareRate, 24000)
        return supportedRates.last(where: { $0 <= capped }) ?? supportedRates[0]
    }

    /// `NARROWBAND_HZ` — below this, speech content above roughly 3.8 kHz (Bluetooth HFP's
    /// ceiling) is already gone before it reaches this policy. 16 kHz itself is the model's
    /// native rate, so it is not narrowband.
    public static func isNarrowband(rate: Int) -> Bool {
        rate < 16000
    }
}
