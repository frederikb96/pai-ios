import PAIKit
import SwiftUI
import UserNotifications

/// Past Recordings — the last `RecordingsStore.maxRecordings` *complete* takes, plus every take
/// the durable pipeline still owes a gap to, whatever their count (`SettingsStore.saveRecording`'s
/// own retention rule). Strictly local: nothing here has ever been uploaded, and this list starts
/// empty on a fresh install even though the account's browser session may have a full one. There
/// is no backend recordings route to sync from, on the web or here.
struct RecordingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    let controller: VoiceRecorderController
    /// Inserts `stt-rec: <text>` into the composer and closes the sheet. `nil` when this sheet
    /// is opened from Settings rather than from a composer: there is nothing to insert into, and
    /// a control that silently does nothing is worse than one that is not there.
    var onInsertTranscript: ((String) -> Void)?
    /// Stages one to three files (raw/sent WAV, or a single combined WAV, plus a JSON report).
    /// `nil` on the same terms as `onInsertTranscript`.
    var onAttach: (([StagedAttachment]) -> Void)?

    @State private var transcribingID: String?
    @State private var errorMessage: String?
    /// `nil` until the one-shot authorization check below resolves — read once, not kept in sync
    /// with a Settings-app toggle flipped while this sheet is open, which is not a case worth
    /// polling for.
    @State private var notificationsAuthorized: Bool?
    @State private var showingNewRecordingPrompt = false
    @State private var newRecordingName = ""

    private let storage = FileRecordingAudioStorage()

    var body: some View {
        NavigationStack {
            Group {
                if settings.recordings.isEmpty && !controller.isRecordingOffline {
                    ContentUnavailableView(
                        "No recordings yet", systemImage: "waveform",
                        description: Text("Recordings you make are kept on this device only.")
                    )
                } else {
                    List {
                        Section {
                            storageHeaderLine
                            if notificationsAuthorized == false {
                                Text("Notifications are off — only the tone will tell you about a drop.")
                                    .font(PaiTypography.caption.font)
                                    .foregroundStyle(PaiPalette.Semantic.warningText)
                            }
                            if controller.isRecordingOffline {
                                offlineRecordingInProgressRow
                            }
                        }
                        ForEach(settings.recordings) { meta in
                            RecordingRow(
                                meta: meta, isTranscribing: transcribingID == meta.id,
                                onTapRetranscribe: { Task { await retranscribe(meta) } },
                                onInsert: onInsertTranscript == nil ? nil : { insert(meta) },
                                onTranscribeRemaining: { controller.transcribeRemainingGaps(id: meta.id) },
                                onAttach: onAttach == nil ? nil : { attach(meta) }
                            )
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    controller.deleteRecording(meta)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Past Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    // A recording made here has nowhere to be transcribed to yet — it just sits
                    // in this same list, named, until Freddy asks for it (tapping the row runs
                    // the same retranscribe flow any other recording already offers).
                    Button {
                        newRecordingName = ""
                        showingNewRecordingPrompt = true
                    } label: {
                        Label("New Recording", systemImage: "record.circle")
                    }
                    .disabled(!controller.canStart)
                    .accessibilityIdentifier("new-offline-recording")
                }
                // Reachable here rather than only from Settings, because this sheet already has a
                // session's composer to attach into — Settings' own "Share Voice Log" has no
                // session to hand the file to, so it goes through the iOS share sheet instead.
                if onAttach != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            attachVoiceLog()
                        } label: {
                            Label("Attach Voice Log", systemImage: "doc.text")
                        }
                        .disabled(AppVoiceDiagnosticsLog.shared.totalSizeBytes() == 0)
                        .accessibilityIdentifier("attach-voice-log")
                    }
                }
            }
            .alert("New Recording", isPresented: $showingNewRecordingPrompt) {
                TextField("Name", text: $newRecordingName)
                Button("Start") {
                    let trimmed = newRecordingName.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await controller.startOfflineRecording(name: trimmed.isEmpty ? "Recording" : trimmed) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Recorded on this device only, transcribed whenever you ask.")
            }
            .alert("Couldn't transcribe recording", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            let notificationSettings = await UNUserNotificationCenter.current().notificationSettings()
            notificationsAuthorized =
                notificationSettings.authorizationStatus == .authorized
                || notificationSettings.authorizationStatus == .provisional
        }
        .accessibilityIdentifier("recordings-sheet")
    }

    private var storageHeaderLine: some View {
        let usedMB = Double(storage.totalBytesUsed()) / 1_000_000
        let freeGB = storage.freeDiskSpaceBytes().map { Double($0) / 1_000_000_000 }
        let freeText = freeGB.map { String(format: "%.1f GB free", $0) } ?? "free space unknown"
        return Text("\(String(format: "%.0f", usedMB)) MB in recordings · \(freeText)")
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
    }

    /// No live duration ticker here on purpose — the same measured-CPU-cost rule that keeps
    /// `VoiceVolumeOverlay` from animating on a flat input applies to a row that would otherwise
    /// redraw once a second for as long as this sheet stays open in the background. The take's
    /// real duration is measured from the captured samples once it stops, same as any other
    /// recording — this row only needs to say that one is running.
    private var offlineRecordingInProgressRow: some View {
        HStack {
            Image(systemName: "record.circle.fill")
                .foregroundStyle(PaiPalette.Semantic.errorText)
            Text("Recording…")
                .font(PaiTypography.bodyEmphasized.font)
            Spacer()
            Button("Stop") { Task { await controller.stop() } }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    /// A fresh, full pass over the whole take — from the untouched raw capture where one was kept
    /// (the batch model accepts any input rate, the entire reason a raw copy is worth keeping),
    /// falling back to the sent audio otherwise. Distinct from `onTranscribeRemaining`, which
    /// only ever fills in a take's open gaps.
    private func retranscribe(_ meta: RecordingMeta) async {
        guard settings.elevenLabsKey.status?.set == true else {
            errorMessage = "Set the ElevenLabs API key on the server first."
            return
        }
        guard let bytes = storage.load(id: meta.id) else {
            errorMessage = "Recording audio data not found."
            return
        }
        transcribingID = meta.id
        defer { transcribingID = nil }

        do {
            let wav = bytes.raw ?? bytes.sent
            let language = Self.language(from: settings.sttLanguage)
            let text = try await controller.transcribe(wav: wav, language: language)
            guard !text.isEmpty else {
                errorMessage = "No speech detected in recording."
                return
            }
            onInsertTranscript?("\(VoiceRecordingResult.sttPrefix)\(text)")
            dismiss()
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
    }

    /// Inserts whatever this take has transcribed so far — complete or not, an inline `…` marker
    /// (`VoiceRecorderController.assembledPrefixedText`'s own convention) stands in for anything
    /// still open.
    private func insert(_ meta: RecordingMeta) {
        guard let text = meta.transcript, !text.isEmpty else {
            errorMessage = "No transcript to insert yet."
            return
        }
        onInsertTranscript?("\(VoiceRecordingResult.sttPrefix)\(text)")
        dismiss()
    }

    /// Stages the recording as attachments: `-raw`/`-sent` when both were kept, a single combined
    /// file when nothing was converted (raw and sent are identical bytes), plus a JSON report —
    /// what makes a bad recording diagnosable rather than merely reproducible.
    private func attach(_ meta: RecordingMeta) {
        guard let bytes = storage.load(id: meta.id) else {
            errorMessage = "Recording audio data not found."
            return
        }
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: meta.timestampMs / 1000))
        var files: [StagedAttachment] = []

        if let raw = bytes.raw, raw != bytes.sent {
            files.append(makeAttachment(data: raw, name: "recording-\(iso)-raw.wav", mime: "audio/wav"))
            files.append(makeAttachment(data: bytes.sent, name: "recording-\(iso)-sent.wav", mime: "audio/wav"))
        } else {
            files.append(makeAttachment(data: bytes.sent, name: "recording-\(iso).wav", mime: "audio/wav"))
        }

        if let reportData = try? RecordingReport.encode(meta) {
            files.append(makeAttachment(data: reportData, name: "recording-\(iso).json", mime: "application/json"))
        }

        onAttach?(files)
        dismiss()
    }

    private func attachVoiceLog() {
        onAttach?([AppVoiceDiagnosticsLog.makeAttachment()])
        dismiss()
    }

    private func makeAttachment(data: Data, name: String, mime: String) -> StagedAttachment {
        StagedAttachment(filename: name, mimeType: mime, data: data, previewImage: nil, originalSize: data.count)
    }

    private static func language(from language: SttLanguage) -> VoiceSettings.Language {
        switch language {
        case .auto: .auto
        case .en: .en
        case .de: .de
        }
    }
}

private struct RecordingRow: View {
    let meta: RecordingMeta
    let isTranscribing: Bool
    var onTapRetranscribe: () -> Void
    var onInsert: (() -> Void)?
    var onTranscribeRemaining: () -> Void
    var onAttach: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                if meta.endedBy == .crashed {
                    Text("Recovered")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                }
                if let nameLine {
                    Text(nameLine)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textSecondary)
                }
                Text(headline)
                    .font(PaiTypography.bodyEmphasized.font)
                if let coverageLine {
                    Text(coverageLine)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(coverageColor)
                }
                if let micLine {
                    Text(micLine)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(
                            meta.narrowband == true ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.textMuted)
                }
                if let captureLine {
                    Text(captureLine)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }
            Spacer()
            if isTranscribing {
                ProgressView()
            } else {
                HStack(spacing: 16) {
                    if hasOpenGaps {
                        Button(action: onTranscribeRemaining) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                        }
                        .accessibilityLabel("Transcribe remaining audio")
                    }
                    if let onInsert, meta.transcript?.isEmpty == false {
                        Button(action: onInsert) {
                            Image(systemName: "text.insert")
                        }
                        .accessibilityLabel("Insert transcript")
                    }
                    if let onAttach {
                        Button(action: onAttach) {
                            Image(systemName: "paperclip")
                        }
                        .accessibilityLabel("Attach recording")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isTranscribing { onTapRetranscribe() } }
    }

    private var hasOpenGaps: Bool { (meta.transcription?.gapCount ?? 0) > 0 }

    private var coverageLine: String? {
        guard let transcription = meta.transcription else { return nil }
        switch transcription.state {
        case .complete: return "Complete"
        case .pending: return "\(Self.durationLabel(ms: transcription.gapMs)) untranscribed"
        case .failed: return "Failed to transcribe \(Self.durationLabel(ms: transcription.gapMs))"
        }
    }

    private var coverageColor: Color {
        switch meta.transcription?.state {
        case .complete, .none: PaiPalette.Semantic.textMuted
        case .pending: PaiPalette.Semantic.warningText
        case .failed: PaiPalette.Semantic.errorText
        }
    }

    private static func durationLabel(ms: Double) -> String {
        let totalSeconds = Int(ms / 1000)
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private var headline: String {
        let date = Date(timeIntervalSince1970: meta.timestampMs / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let duration = Int(meta.durationMs / 1000)
        return "\(formatter.string(from: date)) · \(duration)s"
    }

    /// The marker an offline recording gets in this list — its own name, plus what tells it apart
    /// from an ordinary dictation take at a glance. A named *dictation* take (were one ever to
    /// exist) would show just the name with no marker, though nothing today ever sets `name`
    /// outside `startOfflineRecording(name:)`.
    private var nameLine: String? {
        switch (meta.name, meta.mode) {
        case (let name?, .offline): "\(name) · Offline"
        case (.some(let name), _): name
        case (.none, .offline): "Offline"
        case (.none, _): nil
        }
    }

    private var micLine: String? {
        guard let mic = meta.mic, let sampleRate = meta.sampleRate else { return nil }
        let kHz = sampleRate / 1000
        let narrowbandSuffix = meta.narrowband == true ? " · narrowband" : ""
        return "\(mic.label) · \(String(format: "%.0f", kHz)) kHz\(narrowbandSuffix)"
    }

    private var captureLine: String? {
        var parts: [String] = []
        if let raw = meta.rawSampleRate, let sent = meta.sampleRate, raw != sent {
            parts.append("\(Int(raw / 1000))→\(Int(sent / 1000)) kHz")
        }
        if let peak = meta.levels?.peak, peak > 0 {
            parts.append("peak \(String(format: "%.0f", 20 * log10(peak))) dB")
        }
        if let muted = meta.mutedMs, muted > 0 {
            parts.append("\(Int(muted / 1000))s muted")
        }
        // `triggered` no longer means the take ended by silence -- a gate now resumes on its
        // own once speech returns, so this shows how long it actually withheld audio, the same
        // shape the muted line above already uses.
        if let silence = meta.silence, silence.triggered, silence.gatedMs > 0 {
            parts.append("\(Int(silence.gatedMs / 1000))s silence-gated")
        }
        if meta.rawStored == false {
            parts.append("no raw kept")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A human-readable diagnostic report attached alongside a recording — what turns "here is some
/// audio" into "here is why this take sounded the way it did".
enum RecordingReport {
    static func encode(_ meta: RecordingMeta) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(meta)
    }
}
