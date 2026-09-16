import AVFoundation
import Foundation
import LiveKitWakeWord
import PAIKit

/// Feeds converted microphone audio into one `WakeWordModel` holding a trained classifier per
/// offline-loaded command, and turns its per-round confidence scores into `CommandEvent`s through
/// `WakeWordCommandGate` — the offline half of the command channel, so "Kai start" (and whichever
/// other commands are configured to run offline) works even with the transcription socket down,
/// which is the exact situation this channel exists for. Idle listening is free and fully
/// offline: nothing here ever opens a network connection at all.
///
/// Fed the same converted PCM `MicrophoneCapture.onChunk` already delivers (mono 16-bit at the
/// negotiated transport rate) — a second, independent consumer of the same tap output, not a
/// second capture engine: `WakeWordModel.predict(_:)` takes raw PCM directly, with no
/// `AVAudioEngine` of its own needed. `WakeWordListener`, the package's own convenience wrapper
/// that owns an engine end to end, is the wrong shape here — this app already taps the mic.
///
/// 🚨 Unverified: this file compiles nowhere but a macOS run — see the repository's own note on
/// everything under `PAI/`.
@MainActor
final class WakeWordCommandListener {
    var onCommand: ((CommandEvent) -> Void)?

    private var model: WakeWordModel?
    private var gate: WakeWordCommandGate?
    private var sampleRate: Double = 16_000

    // A rolling window fed to `predict(_:)`, the same ring-buffer shape `WakeWordListener` uses
    // internally — 2s matches the classifiers' own training window; the throttle below matches
    // its ~20ms prediction cadence, and `inflight` keeps two rounds from ever overlapping on one
    // model instance (`WakeWordModel.predict` is documented not reentrant).
    private var ring: [Int16] = []
    private var writeIndex = 0
    private var samplesWritten = 0
    private static let windowSeconds: Double = 2.0
    private static let predictIntervalSeconds: TimeInterval = 0.02
    private var lastPredictAt: Date = .distantPast
    private var inflight = false
    private var takeOffset = 0

    /// Loads a classifier for every command `config.offlineCommands` names that actually has an
    /// `.onnx` file in the app bundle — a command it names with no file present is silently
    /// skipped and reported once through `feedback` (`.commandModelMissing`), never a crash.
    /// Trained models ship as `<CommandKind.modelName>.onnx`; thresholds come from a
    /// `thresholds.json` alongside them, decoded as `WakeWordManifest`, with
    /// `WakeWordManifest.defaultThreshold` standing in for any command that file doesn't name —
    /// see `modelURL(for:)`/`loadManifest()` for exactly where both are looked up.
    func start(config: WakeWordListeningConfig, sampleRate: Double, feedback: @escaping (FeedbackEvent) -> Void) {
        stop()
        self.sampleRate = sampleRate
        let ringSize = max(Int(sampleRate * Self.windowSeconds), 1)
        ring = [Int16](repeating: 0, count: ringSize)

        var urls: [URL] = []
        for kind in config.offlineCommands.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let url = Self.modelURL(for: kind) else {
                feedback(.commandModelMissing(kind))
                continue
            }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }
        do {
            model = try WakeWordModel(models: urls, sampleRate: UInt32(sampleRate))
            gate = WakeWordCommandGate(manifest: Self.loadManifest(), sampleRate: sampleRate)
        } catch {
            // Every command configured to load offline is effectively missing — one event per
            // command rather than inventing a separate "engine failed entirely" case for what is,
            // from the caller's point of view, the same degrade.
            for kind in config.offlineCommands { feedback(.commandModelMissing(kind)) }
            model = nil
            gate = nil
        }
    }

    /// `pcm16le` — the same converted buffer `MicrophoneCapture.onChunk` delivers, never
    /// resampled again here. `atOffset` is this chunk's position in the take, in samples,
    /// matching every other pipeline type's addressing — recorded so the prediction round this
    /// chunk eventually completes carries it.
    func ingest(pcm16le: [Int16], atOffset: Int) {
        takeOffset = atOffset
        guard let model, !ring.isEmpty, !pcm16le.isEmpty else { return }

        var index = writeIndex
        for sample in pcm16le {
            ring[index] = sample
            index += 1
            if index >= ring.count { index = 0 }
        }
        writeIndex = index
        samplesWritten = min(samplesWritten + pcm16le.count, ring.count)
        guard samplesWritten >= ring.count else { return }

        let now = Date()
        guard !inflight, now.timeIntervalSince(lastPredictAt) >= Self.predictIntervalSeconds else { return }
        lastPredictAt = now
        inflight = true

        // Linearize the ring into chronological order before handing it to the model.
        var snapshot = [Int16](repeating: 0, count: ring.count)
        let tail = ring.count - writeIndex
        ring.withUnsafeBufferPointer { source in
            snapshot.withUnsafeMutableBufferPointer { destination in
                guard let sourceBase = source.baseAddress, let destinationBase = destination.baseAddress else {
                    return
                }
                destinationBase.update(from: sourceBase + writeIndex, count: tail)
                if writeIndex > 0 {
                    (destinationBase + tail).update(from: sourceBase, count: writeIndex)
                }
            }
        }

        // Off the main actor: inference is real work, and nothing here may block the UI thread.
        let offset = takeOffset
        Task.detached { [weak self] in
            let scores = (try? model.predict(snapshot)) ?? [:]
            await self?.handle(scores: scores, atOffset: offset)
        }
    }

    private func handle(scores: [String: Float], atOffset: Int) {
        inflight = false
        guard var gate else { return }
        let events = gate.detect(scores: scores, atOffset: atOffset)
        self.gate = gate
        for event in events { onCommand?(event) }
    }

    func stop() {
        model = nil
        gate = nil
        ring = []
        writeIndex = 0
        samplesWritten = 0
        inflight = false
    }
}

extension WakeWordCommandListener {
    private static let modelsSubdirectory = "WakeWordModels"

    /// Looks under `WakeWordModels/` first — where a trained model actually belongs, dropped into
    /// `PAI/Voice/WakeWordModels/` on disk, which needs no `project.pbxproj` edit since `PAI/` is
    /// a synchronized folder — and falls back to a flat bundle lookup so this keeps working
    /// whichever way Xcode's synchronized-folder resource copying ends up flattening it; both are
    /// cheap to check, and only a Mac run can say which one a real build actually needs.
    static func modelURL(for kind: CommandKind) -> URL? {
        Bundle.main.url(forResource: kind.modelName, withExtension: "onnx", subdirectory: modelsSubdirectory)
            ?? Bundle.main.url(forResource: kind.modelName, withExtension: "onnx")
    }

    /// Whether every command in `config.offlineCommands` currently has a bundled model — what the
    /// settings screen shows as each command's own status line, checkable at any time, never only
    /// once a call has actually started.
    static func modelStatus(for config: WakeWordListeningConfig) -> [CommandKind: Bool] {
        Dictionary(uniqueKeysWithValues: config.offlineCommands.map { ($0, modelURL(for: $0) != nil) })
    }

    static func loadManifest() -> WakeWordManifest {
        guard
            let url = Bundle.main.url(
                forResource: "thresholds", withExtension: "json", subdirectory: modelsSubdirectory)
                ?? Bundle.main.url(forResource: "thresholds", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(WakeWordManifest.self, from: data)
        else { return WakeWordManifest() }
        return manifest
    }
}
