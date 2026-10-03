@preconcurrency import AVFoundation
import PAIKit
import SwiftUI

/// What the backend actually handed to each engine — ElevenLabs while dictating, OpenAI while
/// talking to Computer, the wake-word classifier in a call's quiet phase — byte for byte, so a
/// headset or a conversion that distorts the audio can be heard rather than guessed at. The
/// newest few per kind, kept on the backend, so every device lists the same ones.
///
/// Playback downloads the WAV through the authenticated client first: the route needs the bearer
/// header, which a streaming player cannot send.
struct DebugRecordingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store: DebugRecordingsStore
    @State private var kindFilter: String?
    @State private var player: DebugRecordingPlayer

    /// `microphoneBusy` says a take or a call holds the audio session — playback then rides it
    /// rather than switching the session to playback-only under them.
    init(apiClient: PaiApiClient, microphoneBusy: @escaping @MainActor () -> Bool) {
        _store = State(initialValue: DebugRecordingsStore(apiClient: apiClient))
        _player = State(initialValue: DebugRecordingPlayer(microphoneBusy: microphoneBusy))
    }

    private static let kinds = ["dictation", "call_dictation", "wake", "computer"]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Keep debug recordings", isOn: enabledBinding)
                        .disabled(store.enabled == nil)
                        .accessibilityIdentifier("debug-recordings-enabled")
                    filterChips
                    if let error = store.error ?? player.error {
                        Text(error)
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                } footer: {
                    Text("Exactly what each engine heard, kept on the server — the newest few of each kind.")
                }
                ForEach(filtered) { recording in
                    DebugRecordingRow(
                        recording: recording, sameCall: sharesBus(recording),
                        isPlaying: player.playingId == recording.id, isLoading: player.loadingId == recording.id
                    ) {
                        Task { await player.toggle(recording.id, store: store) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            player.stopIfPlaying(recording.id)
                            Task { await store.delete(id: recording.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                if filtered.isEmpty && !store.isLoading {
                    Text("No debug recordings.")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }
            .refreshable { await store.load() }
            .navigationTitle("Debug Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await store.load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .task { await store.load() }
        .onDisappear { player.stop() }
        .accessibilityIdentifier("debug-recordings-sheet")
    }

    private var filtered: [DebugRecording] {
        guard let kindFilter else { return store.recordings }
        return store.recordings.filter { $0.kind == kindFilter }
    }

    private func sharesBus(_ recording: DebugRecording) -> Bool {
        store.recordings.contains { $0.id != recording.id && $0.busId == recording.busId }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.enabled ?? false },
            set: { value in Task { await store.setEnabled(value) } }
        )
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All", kind: nil)
                ForEach(Self.kinds, id: \.self) { kind in
                    chip(title: DebugRecordingRow.kindLabel(kind), kind: kind)
                }
            }
        }
    }

    private func chip(title: String, kind: String?) -> some View {
        Button(title) { kindFilter = kind }
            .buttonStyle(.bordered)
            .tint(kindFilter == kind ? PaiPalette.primary500 : PaiPalette.Semantic.textMuted)
            .font(PaiTypography.caption.font)
    }
}

/// Plays one downloaded recording at a time from a temporary file, deleted again on stop.
@MainActor
@Observable
final class DebugRecordingPlayer {
    private(set) var playingId: String?
    private(set) var loadingId: String?
    private(set) var error: String?
    private var player: AVAudioPlayer?
    private var fileURL: URL?
    private var finishedObserver: Task<Void, Never>?
    private let microphoneBusy: @MainActor () -> Bool

    init(microphoneBusy: @escaping @MainActor () -> Bool) {
        self.microphoneBusy = microphoneBusy
    }

    func toggle(_ id: String, store: DebugRecordingsStore) async {
        if playingId == id {
            stop()
            return
        }
        stop()
        loadingId = id
        defer { loadingId = nil }
        do {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("debug-recording-\(id).wav")
            try await store.downloadAudio(for: id, to: url)
            if !microphoneBusy() {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
                try AVAudioSession.sharedInstance().setActive(true)
            }
            let player = try AVAudioPlayer(contentsOf: url)
            player.play()
            self.player = player
            fileURL = url
            playingId = id
            error = nil
            watchForEnd(of: player)
        } catch {
            self.error = (error as? PaiError)?.userMessage ?? error.localizedDescription
        }
    }

    func stopIfPlaying(_ id: String) {
        if playingId == id { stop() }
    }

    func stop() {
        finishedObserver?.cancel()
        finishedObserver = nil
        player?.stop()
        player = nil
        playingId = nil
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
        fileURL = nil
    }

    /// `AVAudioPlayer`'s delegate needs an `NSObject`; a short poll is all a play button needs to
    /// flip back once the recording has played through.
    private func watchForEnd(of player: AVAudioPlayer) {
        finishedObserver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.player === player else { return }
                if !player.isPlaying {
                    self.stop()
                    return
                }
            }
        }
    }
}

private struct DebugRecordingRow: View {
    let recording: DebugRecording
    let sameCall: Bool
    let isPlaying: Bool
    let isLoading: Bool
    var onPlay: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(PaiTypography.bodyEmphasized.font)
                Text(engineLine)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textSecondary)
                Text(deviceLine)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                if !badges.isEmpty {
                    Text(badges)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                }
            }
            Spacer()
            Button(action: onPlay) {
                if isLoading {
                    ProgressView()
                } else {
                    Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 28))
                }
            }
            .buttonStyle(.borderless)
            .disabled(recording.isStillRecording)
            .accessibilityLabel(isPlaying ? "Stop" : "Play")
        }
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "dictation": "Dictation"
        case "call_dictation": "Call dictation"
        case "wake": "Wake listening"
        case "computer": "Computer"
        default: kind
        }
    }

    private var headline: String {
        let time = IsoTimestamp.date(from: recording.startedAt).map {
            $0.formatted(date: .abbreviated, time: .shortened)
        }
        let seconds = recording.durationMs / 1000
        let duration = "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
        return [Self.kindLabel(recording.kind), time, duration].compactMap { $0 }.joined(separator: " · ")
    }

    private var engineLine: String {
        let engine =
            switch recording.engine {
            case "elevenlabs_realtime", "elevenlabs_batch": "ElevenLabs"
            case "openai_realtime": "OpenAI"
            case "wake_word": "Wake word"
            default: recording.engine
            }
        var parts = ["\(engine) · \(recording.sampleRate / 1000) kHz"]
        if let peak = recording.peakDbfs { parts.append("peak \(String(format: "%.0f", peak)) dBFS") }
        if let session = recording.sessionTitle { parts.append(session) }
        return parts.joined(separator: " · ")
    }

    private var deviceLine: String {
        var parts = [recording.transport]
        if let device = recording.device { parts.append(device) }
        if !recording.mics.isEmpty { parts.append(recording.mics.joined(separator: " → ")) }
        return parts.joined(separator: " · ")
    }

    private var badges: String {
        var parts: [String] = []
        if recording.status != "complete" { parts.append(recording.status) }
        if recording.truncated { parts.append("truncated") }
        if recording.clippedSamples > 0 { parts.append("clipped") }
        if sameCall { parts.append("same call") }
        return parts.joined(separator: " · ")
    }
}
