import Foundation

/// The one rate judgement left once every take is captured at the voice socket's 16 kHz: whether
/// the microphone route itself is narrowband. Judged on the hardware rate, since conversion to
/// 16 kHz cannot restore what an 8 kHz Bluetooth route never delivered.
public enum VoiceAudioRatePolicy {
    /// Below this, speech content above roughly 3.8 kHz (Bluetooth HFP's ceiling) is already gone
    /// before it reaches the converter. 16 kHz itself is the model's native rate, so it is not
    /// narrowband.
    public static func isNarrowband(rate: Int) -> Bool {
        rate < 16000
    }
}
