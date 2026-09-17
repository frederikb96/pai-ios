import Foundation

/// The trained "computer" wake-word classifier's own tuning — its detection threshold. Decoded
/// from a small JSON manifest shipped in the app bundle alongside the classifier itself, so the
/// training run that produces a model can update its threshold without a code change; a manifest
/// missing the key (training still running, or a manifest from an older build) falls back to
/// `defaultThreshold` rather than becoming unloadable.
public struct WakeWordManifest: Codable, Sendable, Equatable {
    public var thresholds: [String: Float]

    public init(thresholds: [String: Float] = [:]) {
        self.thresholds = thresholds
    }

    /// `WakeWordCommandListener`'s own published default — the number the engine falls back to
    /// before a training run's eval step produces a real threshold.
    public static let defaultThreshold: Float = 0.5

    /// The one classifier's own key in `thresholds` — the bundled `.onnx` file's name minus its
    /// extension.
    public static let modelName = "computer"

    public var threshold: Float { thresholds[Self.modelName] ?? Self.defaultThreshold }
}

/// Turns one round of `WakeWordModel.predict(_:)` — a confidence score for the one loaded
/// "computer" classifier — into the rare `CommandEvent`s the call-mode store actually acts on,
/// always `.start`: the offline engine only ever detects the wake word, never a specific command,
/// so what it hands over is "start recording", debounced against the same utterance re-scoring
/// across consecutive prediction windows — a rolling ~2s window sliding a little at a time
/// otherwise crosses threshold on several consecutive rounds for one spoken word.
///
/// Gating is simpler than `CommandDetector`'s text path: a trained spotter already decided "this
/// is the word" by scoring the audio itself, so there is no position gate here, only the
/// threshold (`WakeWordManifest`) and the debounce.
public struct WakeWordDetectionGate: Sendable {
    /// Minimum interval between two fires — long enough to cover one spoken word's window
    /// sliding past threshold repeatedly, short enough that a deliberate second "computer" a
    /// moment later still fires.
    public static let defaultDebounceSeconds: TimeInterval = 1.5

    private let threshold: Float
    private let debounceSamples: Int
    private var lastFiredAtOffset: Int?

    public init(
        manifest: WakeWordManifest, sampleRate: Double,
        debounceSeconds: TimeInterval = WakeWordDetectionGate.defaultDebounceSeconds
    ) {
        self.threshold = manifest.threshold
        self.debounceSamples = Int(sampleRate * debounceSeconds)
    }

    /// `score` is exactly what `WakeWordModel.predict(_:)` returns for the one loaded classifier.
    /// `atOffset` is the take-sample position the audio window used for this prediction round
    /// ends at, the same addressing every other pipeline type uses.
    public mutating func detect(score: Float, atOffset: Int) -> CommandEvent? {
        guard score >= threshold else { return nil }
        if let last = lastFiredAtOffset, atOffset - last < debounceSamples { return nil }
        lastFiredAtOffset = atOffset
        return CommandEvent(kind: .start, atOffset: atOffset, confidence: Double(score))
    }
}
