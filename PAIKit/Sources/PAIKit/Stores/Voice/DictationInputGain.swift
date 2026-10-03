import Foundation

/// A fixed gain on the dictation microphone signal. The iPhone's `.measurement` audio session
/// delivers speech about 8 dB quieter than a browser capture of the same voice, so the converted
/// 16 kHz samples are raised before they reach the uplink, the stored copy, the silence gate and
/// the level meter alike.
public enum DictationInputGain {
    /// Gain in decibels applied to every dictation sample.
    public static let decibels: Double = 8

    /// `decibels` as a linear amplitude factor.
    public static let factor: Double = pow(10, decibels / 20)

    /// `samples` scaled by `factor`, saturating at the Int16 range rather than wrapping.
    public static func apply(to samples: [Int16]) -> [Int16] {
        samples.map { sample in
            let scaled = (Double(sample) * factor).rounded()
            return Int16(min(max(scaled, Double(Int16.min)), Double(Int16.max)))
        }
    }

    /// A `0...1` level reading scaled the same way the samples are, so the meter shows the signal
    /// that is sent.
    public static func apply(toLevel level: Double) -> Double {
        min(level * factor, 1)
    }
}
