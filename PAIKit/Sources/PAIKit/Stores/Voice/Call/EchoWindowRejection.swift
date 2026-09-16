import Foundation

/// Whether a recognised command is the agent's own voice reaching the offline command channel
/// rather than something Freddy said — dropped rather than acted on.
///
/// Deliberately compares wall clock, not take sample offsets. A command's word timestamps
/// (`CommandObservation.wordTimes`) are take-relative — the mic's own addressing scheme — while
/// `SpeechOutputSession.recentPlayback` is wall-clock, since TTS audio has no take offset at all.
/// Reconciling the two needs the take's own start time and sample rate, which belongs to whoever
/// already carries that mapping for the pipeline (`SessionTimeline`); the caller converts a
/// command's word window to wall clock before this ever runs, so this stays provable against
/// plain dates and needs nothing from the pipeline to exist.
public enum EchoWindowRejection {

    /// `commandWindow` is the wall-clock span the offline engine heard the command phrase in;
    /// `commandText` is its recognised text. `playbackWindows` is
    /// `SpeechOutputSession.recentPlayback` (or an equivalent), each entry the wall-clock span one
    /// reply was actually being sent for playback and the text it was speaking.
    ///
    /// Echo needs both: an overlapping window alone would reject any command Freddy happens to
    /// speak while the agent is also talking, which is exactly the barge-in "computer skip" must
    /// keep working; a text match alone would reject a coincidental repeat of the same word.
    public static func isEcho(
        commandWindow: ClosedRange<Date>, commandText: String,
        playbackWindows: [(window: ClosedRange<Date>, text: String)]
    ) -> Bool {
        let needle = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return false }
        return playbackWindows.contains { entry in
            entry.window.overlaps(commandWindow) && entry.text.localizedCaseInsensitiveContains(needle)
        }
    }
}
