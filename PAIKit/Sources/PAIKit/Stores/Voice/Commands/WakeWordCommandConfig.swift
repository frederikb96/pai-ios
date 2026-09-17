import Foundation

/// A trained wake-word classifier's own tuning — its detection threshold, keyed by the model
/// name `CommandKind.modelName` returns (and the bundled `.onnx` file's own name). Decoded from
/// a small JSON manifest shipped in the app bundle alongside the classifiers themselves, so the
/// same training run that produces a model can update its threshold without a code change; a
/// command the manifest doesn't yet name — training still running, or a manifest from an older
/// build — gets `defaultThreshold` rather than becoming unloadable.
public struct WakeWordManifest: Codable, Sendable, Equatable {
    public var thresholds: [String: Float]

    public init(thresholds: [String: Float] = [:]) {
        self.thresholds = thresholds
    }

    /// `WakeWordListener`'s own published default — the number every command falls back to
    /// before a training run's eval step produces a real per-command figure.
    public static let defaultThreshold: Float = 0.5

    public func threshold(for kind: CommandKind) -> Float {
        thresholds[kind.modelName] ?? Self.defaultThreshold
    }
}

/// Which commands the offline wake-word engine loads a classifier for at all. Everything in
/// `CommandKind.allCases` outside this set is recognised only from the ElevenLabs transcript
/// while recording — `CommandGrammar`/`CommandDetector`'s existing text-matching path, unchanged
/// — never through the wake-word engine.
///
/// A configuration choice, not a second code path: Freddy's stated fallback, if several
/// concurrent classifiers prove unreliable together, is loading only `start` offline and
/// recognising everything else from the transcript — `startOnlyFallback` below, not a different
/// mechanism or a different listener.
public struct WakeWordListeningConfig: Sendable, Equatable {
    public var offlineCommands: Set<CommandKind>

    public init(offlineCommands: Set<CommandKind>) {
        self.offlineCommands = offlineCommands
    }

    /// Every command with a trained classifier — `interrupt` is transcript-only by design.
    public static let fullChart = WakeWordListeningConfig(
        offlineCommands: Set(CommandKind.allCases.filter { $0 != .interrupt }))
    public static let startOnlyFallback = WakeWordListeningConfig(offlineCommands: [.start])
}

/// Turns one round of `WakeWordModel.predict(_:)` — a confidence score per loaded classifier,
/// keyed by its model name — into the rare `CommandEvent`s the call-mode store actually acts on.
/// Provable on Linux against synthetic score dictionaries; nothing here has ever run a real
/// classifier or touched real audio.
///
/// Gating is simpler than `CommandDetector`'s text path: a trained spotter already decided "this
/// is the phrase" by scoring the audio itself, so there is no position or pause gate here, only
/// the per-model threshold (`WakeWordManifest`) and a debounce against the same utterance
/// re-scoring across consecutive prediction windows — a rolling ~2s window sliding a little at a
/// time otherwise crosses threshold on several consecutive rounds for one spoken command.
public struct WakeWordCommandGate: Sendable {
    /// Minimum interval between two fires of the *same* command — long enough to cover one
    /// spoken utterance's window sliding past threshold repeatedly, short enough that a
    /// deliberate second "Kai start" a moment later still fires.
    public static let defaultDebounceSeconds: TimeInterval = 1.5

    private let manifest: WakeWordManifest
    private let debounceSamples: Int
    private var lastFiredAtOffset: [CommandKind: Int] = [:]

    public init(
        manifest: WakeWordManifest, sampleRate: Double,
        debounceSeconds: TimeInterval = WakeWordCommandGate.defaultDebounceSeconds
    ) {
        self.manifest = manifest
        self.debounceSamples = Int(sampleRate * debounceSeconds)
    }

    /// `scores` is exactly what `WakeWordModel.predict(_:)` returns — keyed by model name, one
    /// entry per loaded classifier. `atOffset` is the take-sample position the audio window used
    /// for this prediction round ends at, the same addressing every other pipeline type uses.
    /// An unrecognised key (a stray bundled file, a model this build predates) is silently
    /// ignored — the manifest and the loaded-model set are the source of truth for what is
    /// expected, not this gate.
    public mutating func detect(scores: [String: Float], atOffset: Int) -> [CommandEvent] {
        var events: [CommandEvent] = []
        for modelName in scores.keys.sorted() {
            guard let kind = CommandKind(modelName: modelName), let confidence = scores[modelName] else { continue }
            guard confidence >= manifest.threshold(for: kind) else { continue }
            if let last = lastFiredAtOffset[kind], atOffset - last < debounceSamples { continue }
            lastFiredAtOffset[kind] = atOffset
            events.append(CommandEvent(kind: kind, atOffset: atOffset, confidence: Double(confidence)))
        }
        return events
    }
}
