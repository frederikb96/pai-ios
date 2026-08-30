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
    /// The bytes behind past recordings. The list itself belongs to `SettingsStore`, which is
    /// what the settings screen renders and what persists.
    private let recordingAudio: RecordingAudioLibrary

    var state: VoiceRecordingState { voiceSession.state }
    var isMuted: Bool { voiceSession.isMuted }
    var transcribedText: String { voiceSession.transcribedText }
    var lastStartFailure: VoiceStartFailure? { voiceSession.lastStartFailure }

    private let settingsStore: SettingsStore
    private let apiClient: PaiApiClient
    private let capture = MicrophoneCapture()
    private let audioStorage = FileRecordingAudioStorage()
    private let audioSession = AVAudioSession.sharedInstance()

    /// Fixed the moment a take starts, not when it ends — both because `StreamingRecordingFile`
    /// needs its final path before the first sample arrives, and because a take's identity should
    /// be when it began, not roughly when it happened to stop.
    private var takeTimestampMs: Double?
    /// Audio actually sent (already resampled, muted windows zeroed to match what the wire
    /// carried) and the untouched hardware-rate capture — both written to disk as they arrive
    /// rather than held in memory for the whole take, which is what let a take killed near the
    /// end lose everything before it too. `nil` whenever the file could not even be opened, or
    /// (for `streamingRaw`) once the budget below is exceeded.
    private var streamingSent: StreamingRecordingFile?
    private var streamingRaw: StreamingRecordingFile?
    /// The rate `streamingRaw` was opened at — captured once, so a hardware rate change on resume
    /// (a Bluetooth headset reconnecting at a different rate than it dropped at, say) can be
    /// detected and raw capture stopped rather than writing samples a fixed WAV header disagrees
    /// with. The sent stream never has this problem: it is always resampled to the one rate
    /// `VoiceRecordingSession.transportSampleRateHz` fixed for the whole take.
    private var streamingRawSampleRate: Int?
    private var rawBudgetExceeded = false
    private static let rawBudgetSamples = 64 * 1024 * 1024 / 2

    private var peakAmplitude: Double = 0
    private var levelSum: Double = 0
    private var levelCount: Int = 0

    /// `VoiceRecordingSession` can end a take entirely on its own — a reconnect exhausting its
    /// attempts, a protocol error — with no call back into this type at all. Without something
    /// watching for that, `capture` would keep running the microphone into a socket that no
    /// longer exists, and the take would never reach `persistRecording()`. Polling, matching
    /// `ComposerBar.observeLiveTranscript`'s own established pattern for watching this same
    /// `@Observable` session from outside a SwiftUI view body.
    private var sessionWatcherTask: Task<Void, Never>?

    /// `nonisolated(unsafe)` so `deinit` — which is nonisolated — can unregister it. Written
    /// once on the main actor during setup and read once at deallocation, when nothing else holds
    /// a reference, so there is no concurrent access for the isolation to protect.
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    init(apiClient: PaiApiClient, settingsStore: SettingsStore) {
        self.apiClient = apiClient
        self.settingsStore = settingsStore
        self.recordingAudio = RecordingAudioLibrary(storage: audioStorage)

        voiceSession = VoiceRecordingSession(
            dependencies: VoiceRecordingDependencies(
                mintToken: { purpose in try await apiClient.mintVoiceToken(purpose: purpose) },
                makeRealtimeTransport: { URLSessionVoiceRealtimeTransport() },
                // The session is `@MainActor`, so it only ever calls this from the main actor —
                // but the dependency's type cannot say so. Asserting the isolation we already have
                // beats making the settings read `nonisolated`, which it genuinely is not.
                settings: { MainActor.assumeIsolated { Self.voiceSettings(from: settingsStore) } }
            )
        )

        // The list evicts; the audio follows. This is the only thing that deletes a blob, so a
        // recording's bytes cannot outlive its metadata.
        let audio = recordingAudio
        settingsStore.onRecordingEvicted = { meta in
            Task { await audio.delete(id: meta.id) }
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
        VoiceInterruptionNotifier.requestAuthorizationIfNeeded()
        do {
            try configureAudioSession()
        } catch {
            setupFailure = .audioSessionFailed
            return
        }

        let timestampMs = Date().timeIntervalSince1970 * 1000
        takeTimestampMs = timestampMs
        let hardwareRate = capture.hardwareSampleRate
        let transportRate = VoiceAudioRatePolicy.transportRate(hardwareRate: hardwareRate)
        openStreamingFiles(
            id: RecordingMeta.id(forTimestampMs: timestampMs), sentRate: transportRate, rawRate: hardwareRate)
        wireCaptureCallbacks()

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
            sessionWatcherTask?.cancel()
            sessionWatcherTask = Task { [weak self] in await self?.watchForSessionEndingOnItsOwn() }
        } catch {
            // `openStreamingFiles` above already opened this take's files — without persisting
            // (which cleans up on a zero-duration take, same as any other empty take), the open
            // handle and its stub files on disk would just be abandoned here.
            setupFailure = .audioSessionFailed
            capture.stop()
            await voiceSession.stop(reason: .error)
            await persistRecording()
        }
        await startTask.value
    }

    /// Notices a take the session ended by itself — `isCapturing` is the signal that neither
    /// `stop()` nor `giveUpAfterInterruption()` has already run this exact cleanup, both of which
    /// set it `false` before the state transition that would otherwise trigger this too.
    private func watchForSessionEndingOnItsOwn() async {
        while !Task.isCancelled {
            if voiceSession.state == .idle {
                if isCapturing { await handleSessionEndedOnItsOwn() }
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    private func handleSessionEndedOnItsOwn() async {
        capture.stop()
        isCapturing = false
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        await persistRecording()
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
                let type = AVAudioSession.InterruptionType(rawValue: typeValue)
            else { return }
            let optionsValue = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            let shouldResume =
                optionsValue.map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
            Task { @MainActor [weak self] in
                switch type {
                case .began: self?.handleInterruptionBegan()
                case .ended: await self?.handleInterruptionEnded(shouldResume: shouldResume)
                @unknown default: break
                }
            }
        }
    }

    /// The system has already taken the microphone by the time this fires — capture must stop
    /// regardless of what happens next. The take itself only pauses: `PAIKit`'s
    /// `VoiceRecordingSession` keeps the socket and everything transcribed so far, waiting for
    /// `handleInterruptionEnded` to decide whether it can continue.
    private func handleInterruptionBegan() {
        guard isCapturing else { return }
        capture.stop()
        isCapturing = false
        voiceSession.pauseForInterruption()
    }

    /// `shouldResume == false` is documented by Apple for exactly the case where another app
    /// claimed the session for itself — a take that cannot get the microphone back must end
    /// rather than sit paused forever with nothing able to un-pause it.
    private func handleInterruptionEnded(shouldResume: Bool) async {
        guard voiceSession.state == .paused else { return }
        guard shouldResume else {
            await giveUpAfterInterruption()
            return
        }
        do {
            try configureAudioSession()
            // The same target the take started with, not whatever the hardware's own rate is
            // now — a route change mid-call (an AirPod reconnecting, say) must not change what
            // the socket already agreed to receive.
            try capture.start(targetSampleRate: voiceSession.transportSampleRateHz)
            isCapturing = true
            checkRawStreamStillMatchesHardwareRate()
            voiceSession.resumeAfterInterruption()
        } catch {
            await giveUpAfterInterruption()
        }
    }

    private func giveUpAfterInterruption() async {
        await voiceSession.stop(reason: .interrupted)
        try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        await persistRecording()
        VoiceInterruptionNotifier.notify(reason: .interrupted)
    }

    /// The raw stream is fixed at the hardware rate it was opened with; if the route changed
    /// while paused, writing more samples into it would silently disagree with the WAV header
    /// already on disk. The sent stream has no such problem — it stays at the transport rate for
    /// the whole take regardless of hardware changes, per `AVAudioConverter`'s job.
    private func checkRawStreamStillMatchesHardwareRate() {
        guard let streamingRawSampleRate, streamingRawSampleRate != capture.hardwareSampleRate else { return }
        streamingRaw?.finalize()
        streamingRaw = nil
    }

    // MARK: - Capture wiring

    private func openStreamingFiles(id: String, sentRate: Int, rawRate: Int) {
        rawBudgetExceeded = false
        peakAmplitude = 0
        levelSum = 0
        levelCount = 0
        streamingSent = StreamingRecordingFile(url: audioStorage.sentURL(id: id), sampleRate: sentRate)
        streamingRaw = StreamingRecordingFile(url: audioStorage.rawURL(id: id), sampleRate: rawRate)
        streamingRawSampleRate = rawRate
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
                self.streamingSent?.append(pcm16le: effective)
                await self.voiceSession.ingestAudioChunk(pcm16le: samples)
            }
        }
        capture.onRawChunk = { [weak self] samples in
            Task { @MainActor [weak self] in
                guard let self, !self.rawBudgetExceeded, let streamingRaw = self.streamingRaw else { return }
                if streamingRaw.sampleCount + samples.count > Self.rawBudgetSamples {
                    // Stops taking more, but keeps what was already captured — strictly better
                    // than the all-or-nothing discard a fixed in-memory buffer used to force,
                    // and the raw copy was always a diagnostic nicety, never the transcript.
                    self.rawBudgetExceeded = true
                    return
                }
                streamingRaw.append(pcm16le: samples)
            }
        }
    }

    // MARK: - Persisting a finished take

    private func persistRecording() async {
        let result = voiceSession.result
        let sent = streamingSent
        let raw = streamingRaw
        streamingSent = nil
        streamingRaw = nil
        sent?.finalize()
        raw?.finalize()

        guard let timestampMs = takeTimestampMs else { return }
        takeTimestampMs = nil
        let id = RecordingMeta.id(forTimestampMs: timestampMs)

        guard result.durationMs > 0, sent?.hasData == true else {
            // Nothing worth keeping — `start()` already opened files for this id, so clean up the
            // stubs rather than leaving 44-byte orphans behind.
            await audioStorage.delete(id: id)
            return
        }
        let rawKept = raw?.hasData == true
        if !rawKept {
            audioStorage.removeRaw(id: id)
        }

        let settings = Self.voiceSettings(from: settingsStore)
        let averageLevel = levelCount > 0 ? levelSum / Double(levelCount) : 0
        let mic = MicDiagnostics(
            label: currentInputLabel(), trackSampleRate: Double(capture.hardwareSampleRate),
            contextSampleRate: Double(capture.hardwareSampleRate), channelCount: 1,
            echoCancellation: nil, noiseSuppression: nil, autoGainControl: nil, userAgent: "iOS"
        )
        let meta = RecordingMeta(
            timestampMs: timestampMs,
            durationMs: Double(result.durationMs),
            sampleRate: Double(result.sampleRate),
            rawSampleRate: rawKept ? streamingRawSampleRate.map(Double.init) : nil,
            mic: mic,
            rawStored: rawKept,
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
                peak: peakAmplitude, rms: averageLevel, clippedSamples: 0, totalSamples: sent?.sampleCount ?? 0
            ),
            narrowband: result.narrowband,
            startup: nil,
            mutedMs: result.mutedMs > 0 ? Double(result.mutedMs) : nil
        )
        settingsStore.saveRecording(meta)

        if result.endedBy == .connectionLost || result.endedBy == .error {
            VoiceInterruptionNotifier.notify(reason: result.endedBy)
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
