import Foundation

/// Synthesizes the tones `EarconPlayer` plays for a ``FeedbackEvent`` — pure arithmetic, so the
/// cue is provable on Linux even though nothing can confirm on Linux that it is actually audible.
/// Every kind is a short, distinct melody rather than one generic beep, so a drop, a reconnect, a
/// heal and an error are told apart by ear — the whole point of a cue that has to work with the
/// screen off.
public enum Earcon {
    /// One tone: a frequency and how long it plays, in milliseconds.
    private struct Tone {
        let frequency: Double
        let durationMs: Double
    }

    /// Silence between two tones in the same kind — never zero, so two adjacent tones are heard
    /// as two events, not one longer one.
    private static let toneGapMs: Double = 45
    /// The raised-cosine ramp at each tone's own start and end. Without it a tone begins and ends
    /// on a hard edge, which is an audible click rather than a clean cue on phone-speaker
    /// hardware; with it every tone in every kind fades in and out the same way.
    private static let envelopeMs: Double = 5
    /// Held below full scale on purpose — a synthesized cue at Int16 max distorts on a phone
    /// speaker, and this is a notice, not an alarm.
    private static let amplitude: Double = 0.6

    /// Mono, 16-bit little-endian PCM at `sampleRate` — the same shape every other PCM buffer in
    /// this app already carries (`MicrophoneCapture.onChunk`), so `EarconPlayer` needs no
    /// conversion step before scheduling it.
    public static func samples(kind: EarconKind, sampleRate: Double) -> [Int16] {
        tones(for: kind).flatMap { render($0, sampleRate: sampleRate) }
    }

    /// The tones for each kind, in playback order. Frequencies are named notes for the melodic
    /// ones (`healed`'s rising triad) and plain round numbers for the rest — nothing here is a
    /// measured or documented constant, only a deliberately distinct pattern per kind.
    private static func tones(for kind: EarconKind) -> [Tone] {
        switch kind {
        case .drop:
            // Two falling tones.
            return [Tone(frequency: 880, durationMs: 110), Tone(frequency: 660, durationMs: 110)]
        case .reconnect:
            // Two rising tones — the drop tones played in reverse, so the pair reads as "undone".
            return [Tone(frequency: 660, durationMs: 110), Tone(frequency: 880, durationMs: 110)]
        case .healed:
            // Three rising tones — C5, E5, G5.
            return [
                Tone(frequency: 523.25, durationMs: 90), Tone(frequency: 659.25, durationMs: 90),
                Tone(frequency: 783.99, durationMs: 90),
            ]
        case .error:
            // One long, low tone.
            return [Tone(frequency: 220, durationMs: 420)]
        case .pause:
            return [Tone(frequency: 440, durationMs: 140)]
        case .command(let commandKind):
            return [Tone(frequency: commandFrequency(commandKind), durationMs: 90)]
        }
    }

    /// One frequency per command — five confirmations that need to be told apart from each other
    /// as much as from the connection-health cues above.
    private static func commandFrequency(_ kind: CommandKind) -> Double {
        switch kind {
        case .start: return 987.77  // B5
        case .stop: return 392.00  // G4
        case .send: return 659.25  // E5
        case .skip: return 1_174.66  // D6
        case .end: return 523.25  // C5
        case .interrupt: return 783.99  // G5
        }
    }

    private static func render(_ tone: Tone, sampleRate: Double) -> [Int16] {
        let toneFrames = max(1, Int(sampleRate * tone.durationMs / 1000))
        let gapFrames = max(0, Int(sampleRate * toneGapMs / 1000))
        let envelopeFrames = max(1, min(toneFrames / 2, Int(sampleRate * envelopeMs / 1000)))

        var frame = [Int16](repeating: 0, count: toneFrames + gapFrames)
        for index in 0..<toneFrames {
            let phase = 2 * Double.pi * tone.frequency * Double(index) / sampleRate
            let rampIn = min(index, envelopeFrames)
            let rampOut = min(toneFrames - 1 - index, envelopeFrames)
            let envelope = raisedCosine(Double(min(rampIn, rampOut)) / Double(envelopeFrames))
            let magnitude = amplitude * envelope * sin(phase)
            frame[index] = Int16(clamping: Int((magnitude * Double(Int16.max)).rounded()))
        }
        return frame
    }

    /// `t` in `0...1`; 0 at a tone's very edge, 1 once `envelopeMs` in. `min(1, …)` at the call
    /// site means anything past the ramp is already handed 1 and skips the trig here.
    private static func raisedCosine(_ t: Double) -> Double {
        guard t < 1 else { return 1 }
        return (1 - cos(.pi * t)) / 2
    }
}
