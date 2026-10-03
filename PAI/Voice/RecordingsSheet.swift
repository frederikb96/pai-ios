import PAIKit
import SwiftUI
import UIKit
import UserNotifications

/// Past Recordings — the last `SettingsStore.maxRecordings` *complete* takes, plus every take the
/// durable pipeline still owes a gap to, whatever their count (`SettingsStore.saveRecording`'s own
/// retention rule). Strictly local: the audio never leaves this device except as a re-transcribe
/// request, and this list starts empty on a fresh install. What the backend itself heard lives in
/// the debug recordings, not here.
///
/// One sheet, two doors with different meanings for the transcript icon: opened from a session's
/// plus menu it puts the text into that composer; opened from Settings it shows the text to copy.
/// A row tap re-transcribes in both — the result is stored on the recording, never inserted.
struct RecordingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    let controller: VoiceRecorderController
    /// Inserts `stt-rec: <text>` into the composer and closes the sheet. `nil` when this sheet is
    /// opened from Settings, which shows the text in a popup instead.
    var onInsertTranscript: ((String) -> Void)?
    /// Stages the voice diagnostics log in the composer. `nil` from Settings, which shares it.
    var onAttachVoiceLog: ((StagedAttachment) -> Void)?

    @State private var errorMessage: String?
    /// `nil` until the one-shot authorization check below resolves — read once, not kept in sync
    /// with a Settings-app toggle flipped while this sheet is open, which is not a case worth
    /// polling for.
    @State private var notificationsAuthorized: Bool?
    @State private var showingNewRecordingPrompt = false
    @State private var newRecordingName = ""
    @State private var shownTranscript: ShownTranscript?
    @State private var shareFile: AttachmentShareFile?

    private let storage = FileRecordingAudioStorage()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    voiceLogRow
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
                if settings.recordings.isEmpty && !controller.isRecordingOffline {
                    Text("No recordings yet. Recordings you make are kept on this device only.")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
                ForEach(settings.recordings) { meta in
                    RecordingRow(
                        meta: meta, isTranscribing: controller.retranscribingIds.contains(meta.id),
                        transcriptIcon: onInsertTranscript == nil ? "text.bubble" : "text.insert",
                        transcriptLabel: onInsertTranscript == nil ? "Show transcript" : "Insert transcript",
                        onTapRetranscribe: { retranscribe(meta) },
                        onTranscript: { useTranscript(meta) },
                        onTranscribeRemaining: { controller.transcribeRemainingGaps(id: meta.id) }
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
            .navigationTitle("Past Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newRecordingName = ""
                        showingNewRecordingPrompt = true
                    } label: {
                        Label("New Recording", systemImage: "record.circle")
                    }
                    .disabled(!controller.canStart)
                    .accessibilityIdentifier("new-offline-recording")
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
                Text("Not tied to a session. Transcribed automatically once it stops and the phone is online.")
            }
            .alert("Couldn't transcribe recording", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .sheet(item: $shownTranscript) { shown in
                TranscriptPopup(transcript: shown)
            }
            .sheet(item: $shareFile) { file in
                AttachmentShareSheet(activityItems: [file.url])
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

    /// The voice diagnostics log, at the top whichever door opened the sheet: attached to the
    /// composer from a plus menu, shared from Settings.
    private var voiceLogRow: some View {
        Button {
            let attachment = AppVoiceDiagnosticsLog.makeAttachment()
            if let onAttachVoiceLog {
                onAttachVoiceLog(attachment)
                dismiss()
            } else {
                shareFile = AttachmentSharing.stage(attachment.data, filename: attachment.filename)
            }
        } label: {
            Label(
                onAttachVoiceLog == nil ? "Share Voice Log" : "Attach Voice Log",
                systemImage: "doc.text")
        }
        .disabled(AppVoiceDiagnosticsLog.shared.totalSizeBytes() == 0)
        .accessibilityIdentifier("voice-log-from-recordings")
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

    /// A fresh batch pass over the whole take, stored on the recording. Distinct from
    /// `onTranscribeRemaining`, which only fills in a take's open gaps.
    private func retranscribe(_ meta: RecordingMeta) {
        Task {
            do {
                try await controller.retranscribe(id: meta.id)
            } catch {
                errorMessage = (error as? PaiError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func useTranscript(_ meta: RecordingMeta) {
        guard let text = meta.transcript, !text.isEmpty else { return }
        if let onInsertTranscript {
            onInsertTranscript("\(VoiceRecordingResult.sttPrefix)\(text)")
            dismiss()
        } else {
            shownTranscript = ShownTranscript(id: meta.id, title: RecordingRow.headline(for: meta), text: text)
        }
    }
}

/// The transcript a Settings-opened sheet shows, with a Copy button.
private struct ShownTranscript: Identifiable {
    let id: String
    let title: String
    let text: String
}

private struct TranscriptPopup: View {
    @Environment(\.dismiss) private var dismiss
    let transcript: ShownTranscript
    @State private var didCopy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(transcript.text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle(transcript.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = transcript.text
                        didCopy = true
                    } label: {
                        Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("copy-recording-transcript")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct RecordingRow: View {
    let meta: RecordingMeta
    let isTranscribing: Bool
    let transcriptIcon: String
    let transcriptLabel: String
    var onTapRetranscribe: () -> Void
    var onTranscript: () -> Void
    var onTranscribeRemaining: () -> Void

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
                Text(Self.headline(for: meta))
                    .font(PaiTypography.bodyEmphasized.font)
                if let transcriptLine {
                    Text(transcriptLine)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(transcriptLineColor)
                }
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
                    if meta.transcript?.isEmpty == false {
                        Button(action: onTranscript) {
                            Image(systemName: transcriptIcon)
                        }
                        .accessibilityLabel(transcriptLabel)
                        .accessibilityIdentifier("recording-transcript")
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isTranscribing { onTapRetranscribe() } }
        .accessibilityHint("Tap to transcribe again")
    }

    private var hasOpenGaps: Bool { (meta.transcription?.gapCount ?? 0) > 0 }

    /// What the stored transcript is worth: missing, possibly cut short, or a full batch pass.
    private var transcriptLine: String? {
        if meta.transcript?.isEmpty ?? true {
            return meta.mode == .offline ? "Transcribing once online…" : "No transcript · tap to transcribe"
        }
        if meta.transcriptComplete == false { return "Incomplete · tap to re-transcribe" }
        return meta.transcriptSource == .batch ? "Transcribed in full" : nil
    }

    private var transcriptLineColor: Color {
        meta.transcriptComplete == false ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.textMuted
    }

    private var coverageLine: String? {
        guard let transcription = meta.transcription else { return nil }
        switch transcription.state {
        case .complete: return nil
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

    static func headline(for meta: RecordingMeta) -> String {
        let date = Date(timeIntervalSince1970: meta.timestampMs / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let duration = Int(meta.durationMs / 1000)
        return "\(formatter.string(from: date)) · \(duration)s"
    }

    /// A standalone recording's own name, plus what tells it apart from a dictation take.
    private var nameLine: String? {
        switch (meta.name, meta.mode) {
        case (let name?, .offline): "\(name) · Standalone"
        case (.some(let name), _): name
        case (.none, .offline): "Standalone"
        case (.none, _): nil
        }
    }

    private var micLine: String? {
        guard let mic = meta.mic else { return nil }
        let narrowbandSuffix = meta.narrowband == true ? " · narrowband" : ""
        return "\(mic.label)\(narrowbandSuffix)"
    }
}
