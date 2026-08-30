import PAIKit
import SwiftUI

/// Past Recordings — the last `RecordingsStore.maxRecordings`, strictly local: nothing here has
/// ever been uploaded, and this list starts empty on a fresh install even though the account's
/// browser session may have a full one. There is no backend recordings route to sync from, on
/// the web or here.
struct RecordingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    let controller: VoiceRecorderController
    /// Inserts `stt-rec: <text>` into the composer and closes the sheet.
    var onInsertTranscript: (String) -> Void
    /// Stages one to three files (raw/sent WAV, or a single combined WAV, plus a JSON report).
    var onAttach: ([StagedAttachment]) -> Void

    @State private var transcribingID: String?
    @State private var errorMessage: String?

    private let storage = FileRecordingAudioStorage()

    var body: some View {
        NavigationStack {
            Group {
                if settings.recordings.isEmpty {
                    ContentUnavailableView(
                        "No recordings yet", systemImage: "waveform",
                        description: Text("Recordings you make are kept on this device only.")
                    )
                } else {
                    List {
                        ForEach(settings.recordings) { meta in
                            RecordingRow(
                                meta: meta, isTranscribing: transcribingID == meta.id,
                                onTap: { Task { await retranscribe(meta) } },
                                onAttach: { attach(meta) }
                            )
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
            }
            .alert("Couldn't transcribe recording", isPresented: errorBinding) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .accessibilityIdentifier("recordings-sheet")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    /// Re-transcribes from the untouched raw capture where one was kept — the batch model accepts
    /// any input rate, which is the entire reason a raw copy is worth keeping — falling back to
    /// the sent audio otherwise.
    private func retranscribe(_ meta: RecordingMeta) async {
        guard settings.elevenLabsKey.status?.set == true else {
            errorMessage = "Set the ElevenLabs API key in Settings first."
            return
        }
        guard let bytes = storage.load(id: meta.id) else {
            errorMessage = "Recording audio data not found."
            return
        }
        transcribingID = meta.id
        defer { transcribingID = nil }

        do {
            let token = try await controller.mintBatchToken()
            let wav = bytes.raw ?? bytes.sent
            let language = Self.language(from: settings.sttLanguage)
            let result = try await VoiceBatchTranscriber().transcribe(wav: wav, token: token, language: language)
            switch result {
            case .text(let text):
                onInsertTranscript("\(VoiceRecordingResult.sttPrefix)\(text)")
                dismiss()
            case .noSpeechDetected:
                errorMessage = "No speech detected in recording."
            case .failed(let error):
                errorMessage = error.userMessage
            }
        } catch {
            errorMessage = (error as? PaiError)?.userMessage ?? "\(error)"
        }
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

        onAttach(files)
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
    var onTap: () -> Void
    var onAttach: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(PaiTypography.bodyEmphasized.font)
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
                Button(action: onAttach) {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Attach recording")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !isTranscribing { onTap() } }
    }

    private var headline: String {
        let date = Date(timeIntervalSince1970: meta.timestampMs / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let duration = Int(meta.durationMs / 1000)
        return "\(formatter.string(from: date)) · \(duration)s"
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
        if meta.silence?.triggered == true {
            parts.append("silence")
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
