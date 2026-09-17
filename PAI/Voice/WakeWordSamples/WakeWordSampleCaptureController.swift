import AVFoundation
import Foundation
import Observation
import PAIKit

/// Drives the wake-word sample screen's raw, local-only capture — reusing the app's one shared
/// `MicrophoneCapture` engine through the same reservation pattern `CallModeController` already
/// uses (`VoiceRecorderController.reserveForSampleCapture()`), never a second engine. No network,
/// no transcription: every buffer goes straight to a WAV file on disk.
///
/// The engine is started once per run and stays running across every take in it — `next()` only
/// closes one `StreamingRecordingFile` and opens the next, never stops and restarts
/// `AVAudioEngine`. Restarting the engine per tap would reintroduce exactly the latency (and the
/// risk of clipping the first syllable of "Computer") this screen exists to avoid; the sequencing
/// itself — which take is open, what has been finished so far — is `PAIKit`'s
/// `WakeWordSampleRun`, kept here only as the one piece of state this type actually drives.
///
/// 🚨 Unverified: this file compiles nowhere but a macOS run — see the repository's own note on
/// everything under `PAI/`.
@MainActor
@Observable
final class WakeWordSampleCaptureController {
    enum StartFailure: Equatable {
        case microphoneBusy
        case microphoneDenied
        case audioSessionFailed
        case insufficientStorage

        var userMessage: String {
            switch self {
            case .microphoneBusy: "The microphone is busy with a call or a recording — finish that first."
            case .microphoneDenied: "Microphone access is off — enable it in Settings to record."
            case .audioSessionFailed: "Couldn't start the microphone. Try again."
            case .insufficientStorage: "Not enough space to record safely. Free up some storage first."
            }
        }
    }

    /// Why a previously-running run ended on its own, without a tap on Stop — `nil` while idle or
    /// right after a run Freddy himself stopped, which needs no explanation.
    enum RunEndReason: Equatable {
        case microphoneConfigurationChanged
        case interrupted
        case takeTooLong

        var userMessage: String {
            switch self {
            case .microphoneConfigurationChanged:
                "The microphone changed (a headset connected or disconnected) — run stopped."
            case .interrupted: "A call or Siri interrupted — run stopped."
            case .takeTooLong: "Nothing happened for a while — run stopped so the microphone is free again."
            }
        }
    }

    /// A take is one spoken word, so a minute of it means the run was left open — the screen was
    /// navigated away from, or the phone went into a pocket. Ending it here is what keeps a
    /// forgotten run from holding the one microphone (and growing one file) indefinitely.
    private static let takeLimitSeconds: Double = 60

    private(set) var isRunning = false
    /// The take currently open's 1-based position in the run — mirrors
    /// `WakeWordSampleRun.currentTakeIndex` for the view, which has no reason to reach into
    /// `run` itself.
    private(set) var currentTakeIndex: Int?
    private(set) var runKind: WakeWordSample.Kind?
    private(set) var runLabel: String?
    private(set) var startFailure: StartFailure?
    private(set) var lastRunEndReason: RunEndReason?

    private let voice: VoiceRecorderController
    private let store: WakeWordSampleStore
    private let audioStorage: WakeWordSampleAudioStorage
    private let audioSession = AVAudioSession.sharedInstance()

    private var run: WakeWordSampleRun?
    private var runSampleRate: Int?
    private var streaming: StreamingRecordingFile?
    private var takeFileName: String?
    private var takeRecordedAtMs: Double?

    private var chunkContinuation: AsyncStream<[Int16]>.Continuation?
    private var chunkConsumerTask: Task<Void, Never>?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    init(
        voice: VoiceRecorderController, store: WakeWordSampleStore,
        audioStorage: WakeWordSampleAudioStorage = WakeWordSampleAudioStorage()
    ) {
        self.voice = voice
        self.store = store
        self.audioStorage = audioStorage
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    /// What the Start button reads to disable itself — the shared microphone's own three-way
    /// exclusion, read through `VoiceRecorderController` rather than re-derived here.
    var canStart: Bool { voice.canStartSampleCapture }

    // MARK: - Start / next / stop

    /// Begins a run: reserves the shared microphone, configures the same untouched-signal audio
    /// session dictation uses, starts the engine once, and opens the first take. `label` is
    /// Freddy's own free-text note on this batch ("loud windy", "airpods") — sanitized into the
    /// filename, kept verbatim in the manifest.
    func startRun(kind: WakeWordSample.Kind, label: String) async -> Bool {
        guard !isRunning else { return false }
        startFailure = nil
        lastRunEndReason = nil

        guard await voice.ensureMicrophonePermission() else {
            startFailure = .microphoneDenied
            return false
        }
        if let free = FileRecordingAudioStorage().freeDiskSpaceBytes(),
            free < FileRecordingAudioStorage.minimumFreeBytes
        {
            startFailure = .insufficientStorage
            return false
        }
        guard voice.reserveForSampleCapture() else {
            startFailure = .microphoneBusy
            return false
        }
        do {
            try voice.configureAudioSession()
        } catch {
            voice.releaseFromSampleCapture()
            startFailure = .audioSessionFailed
            return false
        }

        let capture = voice.microphoneCapture
        let hardwareRate = capture.hardwareSampleRate
        runSampleRate = hardwareRate
        wireCapture(capture)
        do {
            try capture.start(targetSampleRate: hardwareRate)
        } catch {
            teardownCapture(capture)
            voice.releaseFromSampleCapture()
            startFailure = .audioSessionFailed
            return false
        }

        observeInterruptions()
        run = WakeWordSampleRun(kind: kind, label: label)
        runKind = kind
        runLabel = label
        isRunning = true
        beginTake()
        return true
    }

    /// Finishes the take open since Start (or the previous `next()`) and immediately opens the
    /// next one — no engine restart, so the gap between saying "Computer" the first time and
    /// being ready to say it again is however long the tap itself takes.
    func next() {
        guard isRunning else { return }
        let sample = finalizeCurrentTake()
        try? run?.next(finishing: sample)
        beginTake()
    }

    /// Finishes the open take, ends the run, and hands the microphone back.
    func stopRun() {
        guard isRunning else { return }
        let sample = finalizeCurrentTake()
        try? run?.stop(finishing: sample)
        endRun(reason: nil)
    }

    // MARK: - Per-take bookkeeping

    private func beginTake() {
        guard let run, let sampleRate = runSampleRate else { return }
        let recordedAtMs = Date().timeIntervalSince1970 * 1000
        let fileName = WakeWordSampleNaming.fileName(
            kind: run.kind, label: run.label, index: run.currentTakeIndex ?? 1, recordedAtMs: recordedAtMs)
        takeFileName = fileName
        takeRecordedAtMs = recordedAtMs
        streaming = StreamingRecordingFile(url: audioStorage.url(fileName: fileName), sampleRate: sampleRate)
        takeSampleCount = 0
        currentTakeIndex = run.currentTakeIndex
    }

    /// Closes the currently open `StreamingRecordingFile` and turns it into a `WakeWordSample`
    /// (added to `store` immediately, not held until the run ends — a crash mid-run must not cost
    /// every take already finished). `nil` for a take that captured no audio at all (an instant
    /// double-tap): its stub file is deleted rather than left as a zero-length orphan, and
    /// `WakeWordSampleRun.next(finishing:)`/`stop(finishing:)` already know a `nil` here means
    /// "nothing to append".
    private func finalizeCurrentTake() -> WakeWordSample? {
        guard let file = streaming, let fileName = takeFileName, let recordedAtMs = takeRecordedAtMs,
            let sampleRate = runSampleRate, let run
        else { return nil }
        file.finalize()
        streaming = nil
        takeFileName = nil
        takeRecordedAtMs = nil
        guard file.hasData else {
            audioStorage.delete(fileName: fileName)
            return nil
        }
        let durationMs = Double(file.sampleCount) / Double(sampleRate) * 1000
        let sample = WakeWordSample(
            id: WakeWordSampleNaming.stem(from: fileName), kind: run.kind, label: run.label, fileName: fileName,
            recordedAtMs: recordedAtMs, durationMs: durationMs, sampleRate: sampleRate,
            microphoneRoute: currentInputLabel())
        store.add(sample)
        return sample
    }

    // MARK: - Capture wiring

    /// One ordered consumer for every captured chunk, the same shape
    /// `VoiceRecorderController.wireCaptureCallbacks()`/`CallModeController.wireCaptureIntoCallMode()`
    /// both use: a `Task` per chunk can resume out of order across an `await`, which would write
    /// a take's audio in the wrong order. Explicitly `@MainActor` rather than relying on isolation
    /// inference, so `appendCapturedChunk` below can stay a plain, synchronous call.
    private func wireCapture(_ capture: MicrophoneCapture) {
        capture.onLevel = nil
        capture.onRawChunk = nil
        capture.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in self?.handleConfigurationChange() }
        }
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        chunkContinuation = continuation
        chunkConsumerTask?.cancel()
        chunkConsumerTask = Task { @MainActor [weak self] in
            for await samples in stream {
                self?.appendCapturedChunk(samples)
            }
        }
        capture.onChunk = { samples in continuation.yield(samples) }
    }

    private func appendCapturedChunk(_ samples: [Int16]) {
        streaming?.append(pcm16le: samples)
        takeSampleCount += samples.count
        if let rate = runSampleRate, rate > 0, Double(takeSampleCount) / Double(rate) > Self.takeLimitSeconds {
            endRun(reason: .takeTooLong)
        }
    }

    private var takeSampleCount = 0

    private func teardownCapture(_ capture: MicrophoneCapture) {
        capture.onChunk = nil
        capture.onConfigurationChange = nil
        capture.stop()
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
    }

    // MARK: - Ending unexpectedly

    /// The engine invalidated every tap and connection on it (a headset connecting mid-run, say —
    /// see `MicrophoneCapture.onConfigurationChange`'s own doc comment). Restarting would open the
    /// next take at a possibly different hardware rate than every take already written under this
    /// run's own `runSampleRate`, so the simplest correct answer is to end the run: whatever was
    /// captured before the change is still good audio and is kept, and Freddy starts a fresh run
    /// under the new microphone — exactly the "one run per mic/style" model the screen already
    /// asks for.
    private func handleConfigurationChange() {
        guard isRunning else { return }
        let sample = finalizeCurrentTake()
        try? run?.stop(finishing: sample)
        endRun(reason: .microphoneConfigurationChanged)
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue), type == .began
            else { return }
            Task { @MainActor [weak self] in self?.handleInterruption() }
        }
    }

    /// A phone call or Siri has already taken the microphone by the time this fires. Unlike
    /// dictation, which pauses and tries to resume, this screen is something Freddy is actively
    /// tapping through — simply ending the run and telling him is the whole answer; a resume path
    /// would add real complexity for a case where he is looking at the screen anyway and can just
    /// tap Start again.
    private func handleInterruption() {
        guard isRunning else { return }
        let sample = finalizeCurrentTake()
        try? run?.stop(finishing: sample)
        endRun(reason: .interrupted)
    }

    private func endRun(reason: RunEndReason?) {
        let capture = voice.microphoneCapture
        teardownCapture(capture)
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        voice.releaseFromSampleCapture()
        isRunning = false
        run = nil
        runSampleRate = nil
        runKind = nil
        runLabel = nil
        currentTakeIndex = nil
        lastRunEndReason = reason
    }

    private func currentInputLabel() -> String {
        audioSession.currentRoute.inputs.first?.portName ?? "Microphone"
    }
}
