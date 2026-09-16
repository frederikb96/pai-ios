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
/// Several classifiers sharing "Kai" as their first word can all cross their own threshold for
/// one spoken utterance — `WakeWordCommandArbiter` is what turns that burst into the single
/// highest-scoring `CommandEvent` this hands to `onCommand`, rather than delivering every model
/// that happened to fire.
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

    /// Every command this listener's classifier actually loaded and is scoring — distinct from
    /// `config.offlineCommands`, which is only what Freddy asked for. A caller deciding whether
    /// the transcript fallback should skip a command (because the offline engine already owns
    /// it) must check this, never the raw config: a command the config names but whose `.onnx`
    /// file never made it into the bundle is unreachable by *either* channel if the config alone
    /// decides — the offline engine never fires it, and the fallback stays silent believing the
    /// offline engine has it covered.
    private(set) var loadedCommands: Set<CommandKind> = []

    private var model: WakeWordModel?
    private var gate: WakeWordCommandGate?
    private var arbiter: WakeWordCommandArbiter?
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
    /// `.onnx` file in the app bundle — a command it names with no file present is silently left
    /// out of `loadedCommands`, never a crash. Trained models ship as
    /// `<CommandKind.modelName>.onnx`; thresholds come from a `thresholds.json` alongside them,
    /// decoded as `WakeWordManifest`, with `WakeWordManifest.defaultThreshold` standing in for
    /// any command that file doesn't name — see `modelURL(for:)`/`loadManifest()` for exactly
    /// where both are looked up.
    ///
    /// `feedback` fires **at most once** per call, whatever went wrong and however many commands
    /// it touched — a call that ships with none of its five models bundled would otherwise post
    /// five separate notifications the instant it starts, exactly the "chatty" failure mode
    /// `FeedbackPolicy` exists to collapse everywhere else it can reach. One representative
    /// missing command is enough to point Freddy at the bundle; naming all of them needs a
    /// `FeedbackEvent` case built to carry more than one, which is not this fix's to add.
    func start(config: WakeWordListeningConfig, sampleRate: Double, feedback: @escaping (FeedbackEvent) -> Void) {
        stop()
        self.sampleRate = sampleRate
        let ringSize = max(Int(sampleRate * Self.windowSeconds), 1)
        ring = [Int16](repeating: 0, count: ringSize)

        var found: [(kind: CommandKind, url: URL)] = []
        var firstMissingKind: CommandKind?
        for kind in config.offlineCommands.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let url = Self.modelURL(for: kind) else {
                if firstMissingKind == nil { firstMissingKind = kind }
                continue
            }
            found.append((kind, url))
        }
        guard !found.isEmpty else {
            if let firstMissingKind { feedback(.commandModelMissing(firstMissingKind)) }
            return
        }
        do {
            model = try WakeWordModel(models: found.map(\.url), sampleRate: UInt32(sampleRate))
            gate = WakeWordCommandGate(manifest: Self.loadManifest(), sampleRate: sampleRate)
            arbiter = WakeWordCommandArbiter(sampleRate: sampleRate)
            loadedCommands = Set(found.map(\.kind))
            AppVoiceDiagnosticsLog.shared.log(
                .info, .command,
                "offline engine listening for: \(loadedCommands.map(\.rawValue).sorted().joined(separator: ", "))")
            if let firstMissingKind { feedback(.commandModelMissing(firstMissingKind)) }
        } catch {
            // The engine itself never started, so every command that would have loaded is
            // effectively missing too — `loadedCommands` stays empty either way, and this is
            // still the one notification for the whole failure, not one per command.
            feedback(.commandModelMissing(firstMissingKind ?? found[0].kind))
            model = nil
            gate = nil
            arbiter = nil
            loadedCommands = []
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

    /// Every crossing this round logs — useful on its own in a device log even when it never
    /// reaches `onCommand` — but only ``WakeWordCommandArbiter``'s own winner, if any, is ever
    /// delivered: several classifiers crossing threshold for one spoken utterance is the ordinary
    /// case, not several commands, and `arbiter.observe` is what turns that into at most one.
    private func handle(scores: [String: Float], atOffset: Int) {
        inflight = false
        guard var gate else { return }
        let events = gate.detect(scores: scores, atOffset: atOffset)
        self.gate = gate
        for event in events {
            AppVoiceDiagnosticsLog.shared.log(
                .info, .command,
                "offline detection: \(event.kind.rawValue) at offset \(event.atOffset), "
                    + "confidence \(String(format: "%.2f", event.confidence))")
        }
        guard var arbiter else { return }
        let winner = arbiter.observe(newEvents: events, atOffset: atOffset)
        self.arbiter = arbiter
        guard let winner else { return }
        onCommand?(winner)
    }

    func stop() {
        model = nil
        gate = nil
        arbiter = nil
        ring = []
        writeIndex = 0
        samplesWritten = 0
        inflight = false
        loadedCommands = []
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
