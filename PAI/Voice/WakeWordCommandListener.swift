import AVFoundation
import Foundation
import LiveKitWakeWord
import PAIKit

/// Feeds converted microphone audio into one `WakeWordModel` holding the single "computer"
/// classifier and turns its per-round confidence score into a debounced `CommandEvent` — the
/// offline half of the command channel, so waking a call up works even with the transcription
/// socket down, which is the exact situation this channel exists for. Idle listening is free and
/// fully offline: nothing here ever opens a network connection at all.
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
    /// Always fired with `.start` — the only thing an offline wake-word detection ever means.
    var onCommand: ((CommandEvent) -> Void)?

    private(set) var isLoaded = false

    private var model: WakeWordModel?
    private var gate: WakeWordDetectionGate?
    private var sampleRate: Double = 16_000

    // A rolling window fed to `predict(_:)`, the same ring-buffer shape `WakeWordListener` uses
    // internally — 2s matches the classifier's own training window; the throttle below matches
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
    private var heartbeat = WakeWordHeartbeat()
    private var failureLog = LogThrottle(interval: 5)

    /// Loads the "computer" classifier from the app bundle — a no-op, `isLoaded` left `false`,
    /// when it was never bundled (training still running, or a build predating it), never a
    /// crash.
    func start(sampleRate: Double, feedback: @escaping (FeedbackEvent) -> Void) {
        stop()
        self.sampleRate = sampleRate
        let ringSize = max(Int(sampleRate * Self.windowSeconds), 1)
        ring = [Int16](repeating: 0, count: ringSize)

        guard let url = Self.modelURL() else {
            feedback(.commandModelMissing(.start))
            return
        }
        do {
            // CPU inference, never CoreML: iOS refuses GPU work to a backgrounded app, and the
            // phone is locked in a pocket for most of a call — the one state this engine exists
            // for. A denied round returns nothing, which is indistinguishable from nobody having
            // said the word.
            model = try WakeWordModel(models: [url], sampleRate: UInt32(sampleRate), executionProvider: .cpu)
            gate = WakeWordDetectionGate(manifest: Self.loadManifest(), sampleRate: sampleRate)
            isLoaded = true
            AppVoiceDiagnosticsLog.shared.log(.info, .command, "offline engine listening for \"computer\"")
        } catch {
            feedback(.commandModelMissing(.start))
            model = nil
            gate = nil
            isLoaded = false
        }
    }

    /// `pcm16le` — the same converted buffer `MicrophoneCapture.onChunk` delivers, never
    /// resampled again here. `atOffset` is this chunk's position in the take, in samples,
    /// matching every other pipeline type's addressing — recorded so the prediction round this
    /// chunk eventually completes carries it.
    func ingest(pcm16le: [Int16], atOffset: Int) {
        takeOffset = atOffset
        guard let model, !ring.isEmpty, !pcm16le.isEmpty else { return }
        heartbeat.chunkIngested()
        if let line = heartbeat.due(at: Date()) {
            AppVoiceDiagnosticsLog.shared.log(.info, .command, line)
        }

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
            do {
                let scores = try model.predict(snapshot)
                await self?.handle(score: scores[WakeWordManifest.modelName], atOffset: offset)
            } catch {
                await self?.handleFailure(error)
            }
        }
    }

    /// Clears `inflight` exactly as `handle` does — a failure path that forgets it stops the
    /// engine for the rest of the call, since no further round is ever allowed to start.
    private func handleFailure(_ error: Error) {
        inflight = false
        heartbeat.roundFailed()
        guard failureLog.allows(at: Date()) else { return }
        AppVoiceDiagnosticsLog.shared.log(.error, .command, "offline prediction failed: \(error)")
    }

    private func handle(score: Float?, atOffset: Int) {
        inflight = false
        heartbeat.roundCompleted(score: score)
        guard var gate, let score else { return }
        let event = gate.detect(score: score, atOffset: atOffset)
        self.gate = gate
        guard let event else { return }
        AppVoiceDiagnosticsLog.shared.log(
            .info, .command,
            "offline detection at offset \(event.atOffset), confidence \(String(format: "%.2f", event.confidence))")
        onCommand?(event)
    }

    func stop() {
        heartbeat = WakeWordHeartbeat()
        failureLog = LogThrottle(interval: 5)
        model = nil
        gate = nil
        ring = []
        writeIndex = 0
        samplesWritten = 0
        inflight = false
        isLoaded = false
    }
}

extension WakeWordCommandListener {
    private static let modelsSubdirectory = "WakeWordModels"

    /// Looks under `WakeWordModels/` first — where a trained model actually belongs, dropped into
    /// `PAI/Voice/WakeWordModels/` on disk, which needs no `project.pbxproj` edit since `PAI/` is
    /// a synchronized folder — and falls back to a flat bundle lookup so this keeps working
    /// whichever way Xcode's synchronized-folder resource copying ends up flattening it; both are
    /// cheap to check, and only a Mac run can say which one a real build actually needs.
    static func modelURL() -> URL? {
        Bundle.main.url(
            forResource: WakeWordManifest.modelName, withExtension: "onnx", subdirectory: modelsSubdirectory)
            ?? Bundle.main.url(forResource: WakeWordManifest.modelName, withExtension: "onnx")
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
