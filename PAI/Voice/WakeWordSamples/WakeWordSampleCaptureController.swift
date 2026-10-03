import AVFoundation
import Foundation
import Observation
import PAIKit

/// Records wake-word sample runs and hands every take to the upload queue the moment it closes.
///
/// Capture goes through the call path (`ComputerAudioIO`: `.voiceChat`, converted to 16 kHz),
/// not dictation's untouched `.measurement` capture — the live classifier hears exactly that path
/// during a call's quiet phase, so samples recorded through it match what it will be judged on,
/// and they arrive at the 16 kHz mono the backend corpus accepts.
///
/// The engine starts once per run and keeps running across every take: Next closes one file and
/// opens the next, never restarting audio, so the gap between saying "Computer" and being ready to
/// say it again is the tap itself. The sequencing is `WakeWordSampleRun`; the queue is
/// `WakeWordUploadQueue`; this type owns only capture and the files in between.
///
/// App-wide, like the other two microphone owners, so a queued upload keeps draining whatever
/// screen is open — and refused while either of them holds the microphone.
@MainActor
@Observable
final class WakeWordSampleCaptureController {
    enum StartFailure: Equatable {
        case microphoneBusy
        case microphoneDenied
        case audioFailed

        var userMessage: String {
            switch self {
            case .microphoneBusy: "The microphone is busy with a call or a recording — finish that first."
            case .microphoneDenied: "Microphone access is off — enable it in Settings to record."
            case .audioFailed: "Couldn't start the microphone. Try again."
            }
        }
    }

    /// Why a run ended without Stop being tapped.
    enum RunEndReason: Equatable {
        case microphoneChanged
        case interrupted
        case takeTooLong

        var userMessage: String {
            switch self {
            case .microphoneChanged: "The microphone changed — run stopped. Start a new run for the new microphone."
            case .interrupted: "A call or Siri interrupted — run stopped."
            case .takeTooLong: "Nothing happened for a while — run stopped so the microphone is free again."
            }
        }
    }

    /// A take is one spoken word, so a minute of it means the run was left open.
    private static let takeLimitSeconds = 60
    private static let sampleRate = VoiceSocketProtocol.audioUplinkHz

    let queue: WakeWordUploadQueue
    private(set) var isRunning = false
    private(set) var currentTakeIndex: Int?
    private(set) var runKind: WakeWordSampleKind?
    private(set) var runLabel: String?
    private(set) var startFailure: StartFailure?
    private(set) var lastRunEndReason: RunEndReason?
    /// What the backend holds, as of the last refresh.
    private(set) var storedRuns: [WakeWordRun] = []
    private(set) var listError: String?

    private let apiClient: PaiApiClient
    private let voice: VoiceRecorderController
    private let computerCall: ComputerCallController
    private let files = WakeWordSampleFiles()
    private let audioIO = ComputerAudioIO()
    private let audioSession = AVAudioSession.sharedInstance()
    private let pathObserver = NetworkPathObserver()

    private var run: WakeWordSampleRun?
    private var streaming: StreamingRecordingFile?
    private var takeId: String?
    private var takeRecordedAt: Date?
    private var takeSampleCount = 0
    private var chunkContinuation: AsyncStream<[Int16]>.Continuation?
    private var chunkConsumerTask: Task<Void, Never>?
    private nonisolated(unsafe) var interruptionObserver: NSObjectProtocol?

    init(
        apiClient: PaiApiClient, storage: SettingsKeyValueStore, voice: VoiceRecorderController,
        computerCall: ComputerCallController
    ) {
        self.apiClient = apiClient
        self.voice = voice
        self.computerCall = computerCall
        queue = WakeWordUploadQueue(storage: storage, transport: apiClient, files: WakeWordSampleFiles())
        pathObserver.onEvent = { [weak self] event in
            guard case .pathSatisfied(true) = event else { return }
            Task { @MainActor [weak self] in self?.drain() }
        }
        pathObserver.start()
        audioIO.onConfigurationChange = { [weak self] in
            Task { @MainActor [weak self] in self?.endRunEarly(.microphoneChanged) }
        }
    }

    deinit {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        pathObserver.stop()
    }

    var canStart: Bool { !isRunning && voice.state == .idle && !voice.isRecordingOffline && !computerCall.isLive }

    // MARK: - Listing, deleting, uploading

    /// Uploads whatever is queued, then re-reads what the backend holds.
    func drain() {
        Task {
            await queue.drain()
            await refresh()
        }
    }

    func refresh() async {
        do {
            storedRuns = try await apiClient.listWakeWordRuns()
            listError = nil
        } catch {
            listError = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    /// A run still on its way up is dropped here with its audio; one the backend holds is deleted
    /// there too. A run can be both, mid-upload.
    func deleteRun(id: String) async {
        if id == run?.id { return }
        queue.removeRun(id: id)
        if storedRuns.contains(where: { $0.id == id }) {
            do {
                try await apiClient.deleteWakeWordRun(id: id)
            } catch {
                listError = (error as? PaiError)?.userMessage ?? "\(error)"
            }
        }
        await refresh()
    }

    // MARK: - Start / next / stop

    func startRun(kind: WakeWordSampleKind, label: String) async {
        guard canStart else {
            startFailure = .microphoneBusy
            return
        }
        startFailure = nil
        lastRunEndReason = nil
        guard await requestMicrophonePermission() else {
            startFailure = .microphoneDenied
            return
        }
        wireCapture()
        do {
            try audioIO.start()
        } catch {
            teardownCapture()
            startFailure = .audioFailed
            return
        }
        observeInterruptions()

        let runId = UUID().uuidString.lowercased()
        queue.openRun(
            id: runId,
            upload: WakeWordRunUpload(
                kind: kind, label: label, device: VoiceDevice.deviceName, mic: VoiceDevice.currentMicrophone,
                createdAt: Self.iso(Date())))
        run = WakeWordSampleRun(id: runId, kind: kind, label: label)
        runKind = kind
        runLabel = label
        isRunning = true
        beginTake()
        drain()
    }

    /// Finishes the open take and opens the next in the same tap — no engine restart.
    func next() {
        guard isRunning else { return }
        let take = finalizeCurrentTake()
        try? run?.next(finishing: take)
        beginTake()
        drain()
    }

    func stopRun() {
        guard isRunning else { return }
        let take = finalizeCurrentTake()
        try? run?.stop(finishing: take)
        endRun(reason: nil)
    }

    // MARK: - Per-take bookkeeping

    private func beginTake() {
        guard let run else { return }
        let id = UUID().uuidString.lowercased()
        takeId = id
        takeRecordedAt = Date()
        takeSampleCount = 0
        streaming = StreamingRecordingFile(url: files.url(fileName: "\(id).wav"), sampleRate: Self.sampleRate)
        currentTakeIndex = run.currentTakeIndex
    }

    /// Closes the open file and queues it — straight away, not at the end of the run, so a crash
    /// mid-run costs at most the take that was open. A take with no audio (an instant double tap)
    /// is deleted rather than queued.
    private func finalizeCurrentTake() -> WakeWordPendingTake? {
        guard let file = streaming, let id = takeId, let recordedAt = takeRecordedAt, let run,
            let index = run.currentTakeIndex
        else { return nil }
        file.finalize()
        streaming = nil
        takeId = nil
        takeRecordedAt = nil
        let fileName = "\(id).wav"
        guard file.hasData else {
            files.delete(fileName: fileName)
            return nil
        }
        let take = WakeWordPendingTake(
            id: id, index: index, recordedAt: Self.iso(recordedAt),
            durationMs: file.sampleCount * 1000 / Self.sampleRate, fileName: fileName)
        queue.addTake(runId: run.id, take: take)
        return take
    }

    // MARK: - Capture

    /// One ordered consumer for every captured chunk — a `Task` per chunk can resume out of order
    /// and write a take's audio scrambled.
    private func wireCapture() {
        let (stream, continuation) = AsyncStream<[Int16]>.makeStream()
        chunkContinuation = continuation
        chunkConsumerTask?.cancel()
        chunkConsumerTask = Task { @MainActor [weak self] in
            for await samples in stream {
                self?.append(samples)
            }
        }
        audioIO.onMicChunk = { samples in continuation.yield(samples) }
    }

    private func append(_ samples: [Int16]) {
        streaming?.append(pcm16le: samples)
        takeSampleCount += samples.count
        if takeSampleCount > Self.takeLimitSeconds * Self.sampleRate {
            endRunEarly(.takeTooLong)
        }
    }

    private func teardownCapture() {
        audioIO.onMicChunk = nil
        audioIO.stop()
        chunkConsumerTask?.cancel()
        chunkConsumerTask = nil
        chunkContinuation?.finish()
        chunkContinuation = nil
    }

    /// A route change (a headset connecting) or an interruption: what was captured before it is
    /// kept, and a fresh run under the new conditions is the clean answer — one run per
    /// microphone is the model the screen asks for anyway.
    private func endRunEarly(_ reason: RunEndReason) {
        guard isRunning else { return }
        let take = finalizeCurrentTake()
        try? run?.stop(finishing: take)
        endRun(reason: reason)
    }

    private func endRun(reason: RunEndReason?) {
        teardownCapture()
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        interruptionObserver = nil
        if let run { queue.closeRun(id: run.id) }
        isRunning = false
        run = nil
        runKind = nil
        runLabel = nil
        currentTakeIndex = nil
        lastRunEndReason = reason
        drain()
    }

    private func observeInterruptions() {
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: audioSession, queue: .main
        ) { [weak self] notification in
            guard let typeValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                AVAudioSession.InterruptionType(rawValue: typeValue) == .began
            else { return }
            Task { @MainActor [weak self] in self?.endRunEarly(.interrupted) }
        }
    }

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

    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
