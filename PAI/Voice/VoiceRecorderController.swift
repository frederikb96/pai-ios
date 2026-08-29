import AVFoundation
import Foundation
import Observation
import PAIKit

/// Ties `PAIKit`'s `VoiceRecordingSession` (the tested decision core: state machine, wire
/// protocol, silence semantics, prefixing) to what only a real device can supply: microphone
/// capture, `AVAudioSession` configuration and interruption/permission handling, and where a
/// finished recording's bytes and metadata actually land.
///
/// One instance per composer. Unlike `DraftStore`, a fresh instance per session view is fine —
/// nothing about an in-flight recording needs to survive navigating away, and past recordings are
/// reloaded from `SettingsStore.recordings` (the persisted list) on every construction, not held
/// only in memory.
@MainActor
@Observable
final class VoiceRecorderController {
    enum SetupFailure: Equatable {
        case microphoneDenied
        case audioSessionFailed
    }

    private(set) var voiceSession: VoiceRecordingSession
    private(set) var isCapturing = false
    private(set) var setupFailure: SetupFailure?
    /// Recordings this device has ever kept, newest first — seeded from `SettingsStore.recordings`
    /// (the persisted metadata) at construction, kept in sync with it on every new capture.
    private(set) var recordings: RecordingsStore

    var state: VoiceRecordingState { voiceSession.state }
    var isMuted: Bool { voiceSession.isMuted }
    var transcribedText: String { voiceSession.transcribedText }
    var lastStartFailure: VoiceStartFailure? { voiceSession.lastStartFailure }

    private let settingsStore: SettingsStore
    private let apiClient: PaiApiClient
    private let capture = MicrophoneCapture()
    private let audioStorage = FileRecordingAudioStorage()
    private let audioSession = AVAudioSession.sharedInstance()

    /// Accumulated for the recording currently in progress — the audio actually sent (already
    /// resampled, muted windows zeroed to match what the wire actually carried) and the untouched
    /// hardware-rate capture, kept only while under `rawBudgetSamples` — mirroring the web's
    /// `RAW_BUDGET_BYTES` so a mic left open cannot grow this without bound.
    private var sentSamples: [Int16] = []
    private var rawSamples: [Int16] = []
    private var rawBudgetExceeded = false
    private static let rawBudgetSamples = 64 * 1024 * 1024 / 2

    private var peakAmplitude: Double = 0
    private var levelSum: Double = 0
    private var levelCount: Int = 0

    private var interruptionObserver: NSObjectProtocol?

    init(apiClient: PaiApiClient, settingsStore: SettingsStore) {
        self.apiClient = apiClient
        self.settingsStore = settingsStore
        self.recordings = RecordingsStore(storage: audioStorage, initial: settingsStore.recordings)

        voiceSession = VoiceRecordingSession(
            dependencies: VoiceRecordingDependencies(
                mintToken: { purpose in try await apiClient.mintVoiceToken(purpose: purpose) },
                makeRealtimeTransport: { URLSessionVoiceRealtimeTransport() },
                settings: { Self.voiceSettings(from: settingsStore) }
            )
        )

        // `SettingsStore` is the persisted metadata authority and has no audio storage of its
        // own — this is the seam its own doc comment describes for whoever does. Kept even
        // though `persistRecording()` below drives both lists from the same call and they never
        // actually disagree: it is what makes that agreement a property of the wiring rather than
        // an invariant a future change could quietly break.
        let recordingsStore = recordings
        settingsStore.onRecordingEvicted = { meta in
            Task { await recordingsStore.remove(id: meta.id) }
        }

        observeInterruptions()
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
    }

    var canStart: Bool {
        voiceSession.canStart && settingsStore.elevenLabsKey.status?.set != false
    }

    // MARK: - Start / stop

    func start() async {
        guard voiceSession.canStart else { return }
        setupFailure = nil

        guard await requestMicrophonePermission() else {
            setupFailure = .microphoneDenied
            return
        }
        do {
            try configureAudioSession()
        } catch {
            setupFailure = .audioSessionFailed
            return
        }

        resetTakeBuffers()
        wireCaptureCallbacks()

        let hardwareRate = capture.hardwareSampleRate
        let transportRate = VoiceAudioRatePolicy.transportRate(hardwareRate: hardwareRate)

        let startTask = Task { await voiceSession.start(hardwareSampleRate: hardwareRate) }
        // `VoiceRecordingSession.start()` flips `state` to `.connecting` synchronously, before its
        // first `await` — waiting for that to become observable (rather than a fixed delay) is
        // what lets capture begin the moment the session can accept chunks, so the pre-connect
        // buffer actually protects the start of the take instead of racing it.
        var guardIterations = 0
        while voiceSession.state == .idle && guardIterations < 200 {
            await Task.yield()
            guardIterations += 1
        }

        do {
            try capture.start(targetSampleRate: transportRate)
            isCapturing = true
        } catch {
            setupFailure = .audioSessionFailed
            capture.stop()
            await voiceSession.stop(reason: .error)
        }
        await startTask.value
    }

    func toggleMute() {
        voiceSession.toggleMute()
    }

    /// A fresh single-use batch token for re-transcribing a past recording — minted here rather
    /// than cached anywhere, the same discipline the realtime path follows: caching a single-use
    /// token is a bug, not an optimisation.
    func mintBatchToken() async throws -> String {
        try await apiClient.mintVoiceToken(purpose: .batch).token
    }

    /// Stops the take, persists the recording (audio + metadata), and returns the composer-ready
    /// prefixed text for the caller to insert.
    @discardableResult
    func stop() async -> String {
        guard isCapturing || voiceSession.state != .idle else { return "" }
        capture.stop()
        isCapturing = false
        await voiceSession.stop(reason: .user)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)

        await persistRecording()
        return voiceSession.result.prefixedText
    }

    // MARK: - Permission

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: - Audio session

    private func configureAudioSession() throws {
        try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetooth])
        try audioSession.setActive(true)
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main
        ) { [weak self] notification in
            guard
                let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: typeValue), type == .began
            else { return }
            Task { @MainActor [weak self] in
                await self?.handleInterruption()
            }
        }
    }

    /// Ends the take and keeps the words transcribed so far — the same policy the web applies to
    /// its audio context being suspended in the background. A call, Siri, or another app taking
    /// the microphone all arrive here.
    private func handleInterruption() async {
        guard isCapturing else { return }
        capture.stop()
        isCapturing = false
        await voiceSession.handleInterruption()
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        await persistRecording()
    }

    // MARK: - Capture wiring

    private func resetTakeBuffers() {
        sentSamples = []
        rawSamples = []
        rawBudgetExceeded = false
        peakAmplitude = 0
        levelSum = 0
        levelCount = 0
    }

    private func wireCaptureCallbacks() {
        capture.onLevel = { [weak self] rms in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.voiceSession.ingestLevel(rms: rms)
                self.peakAmplitude = max(self.peakAmplitude, rms)
                self.levelSum += rms
                self.levelCount += 1
            }
        }
        capture.onChunk = { [weak self] samples in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Mirrors what `VoiceRecordingSession.ingestAudioChunk` actually transmits when
                // muted — the socket receives zeroes, so the saved "sent" recording should too,
                // rather than silently disagreeing with what ElevenLabs was given.
                let effective = self.voiceSession.isMuted ? [Int16](repeating: 0, count: samples.count) : samples
                self.sentSamples.append(contentsOf: effective)
                await self.voiceSession.ingestAudioChunk(pcm16le: samples)
            }
        }
        capture.onRawChunk = { [weak self] samples in
            Task { @MainActor [weak self] in
                guard let self, !self.rawBudgetExceeded else { return }
                if self.rawSamples.count + samples.count > Self.rawBudgetSamples {
                    self.rawBudgetExceeded = true
                    self.rawSamples = []
                    return
                }
                self.rawSamples.append(contentsOf: samples)
            }
        }
    }

    // MARK: - Persisting a finished take

    private func persistRecording() async {
        let result = voiceSession.result
        guard result.durationMs > 0 else { return }

        let sentWav = PcmWavWriter.wrap(pcm16le: sentSamples, sampleRate: result.sampleRate)
        let rawWav: Data? =
            (rawBudgetExceeded || rawSamples.isEmpty)
            ? nil : PcmWavWriter.wrap(pcm16le: rawSamples, sampleRate: capture.hardwareSampleRate)

        let settings = Self.voiceSettings(from: settingsStore)
        let averageLevel = levelCount > 0 ? levelSum / Double(levelCount) : 0
        let mic = MicDiagnostics(
            label: currentInputLabel(), trackSampleRate: Double(capture.hardwareSampleRate),
            contextSampleRate: Double(capture.hardwareSampleRate), channelCount: 1,
            echoCancellation: nil, noiseSuppression: nil, autoGainControl: nil, userAgent: "iOS"
        )
        let meta = RecordingMeta(
            timestampMs: Date().timeIntervalSince1970 * 1000,
            durationMs: Double(result.durationMs),
            sampleRate: Double(result.sampleRate),
            rawSampleRate: rawWav != nil ? Double(capture.hardwareSampleRate) : nil,
            mic: mic,
            rawStored: rawWav != nil,
            endedBy: result.endedBy,
            silence: SilenceMeta(
                enabled: settings.silenceDetectionEnabled, threshold: settings.silenceThreshold,
                durationMs: Double(settings.silenceDurationMs), triggered: result.endedBy == .silence
            ),
            stt: SttMeta(
                model: VoiceRealtimeProtocol.modelId, language: settings.sttLanguage.rawValue,
                vadSilenceSecs: Double(VoiceRealtimeProtocol.vadSilenceThresholdSecs) ?? 1.5,
                vadThreshold: Double(VoiceRealtimeProtocol.vadThreshold) ?? 0.4
            ),
            transcript: result.text.isEmpty ? nil : result.text,
            levels: LevelStats(
                peak: peakAmplitude, rms: averageLevel, clippedSamples: 0, totalSamples: sentSamples.count
            ),
            narrowband: result.narrowband,
            startup: nil,
            mutedMs: result.mutedMs > 0 ? Double(result.mutedMs) : nil
        )

        do {
            try await recordings.add(meta, raw: rawWav, sent: sentWav)
            settingsStore.saveRecording(meta)
        } catch {
            // Losing a diagnostics recording is not worth surfacing to Freddy — the transcript
            // it already produced has already reached the composer regardless.
        }
    }

    private func currentInputLabel() -> String {
        audioSession.currentRoute.inputs.first?.portName ?? "Microphone"
    }

    // MARK: - Settings mapping

    /// `SettingsStore` persists `SttLanguage` (this app's own enum, deliberately with no
    /// provider-fallback case); `VoiceRecordingSession` speaks `VoiceSettings.Language` (the
    /// package's port of the same three web values). Same three cases, two independent enums —
    /// this is the one place that needs to know that.
    private static func voiceSettings(from settingsStore: SettingsStore) -> VoiceSettings {
        let language: VoiceSettings.Language =
            switch settingsStore.sttLanguage {
            case .auto: .auto
            case .en: .en
            case .de: .de
            }
        return VoiceSettings(
            sttLanguage: language,
            micDeviceId: settingsStore.micDeviceId,
            silenceDetectionEnabled: settingsStore.silenceDetectionEnabled,
            silenceThreshold: settingsStore.silenceThreshold,
            silenceDurationMs: Int(settingsStore.silenceDurationMs)
        )
    }
}
