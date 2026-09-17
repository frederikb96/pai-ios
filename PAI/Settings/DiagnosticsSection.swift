import PAIKit
import SwiftUI
import UIKit

/// The diagnostic lists at the bottom of the panel, not settings themselves — a recovery aid for a
/// message that did not land, a record of what voice capture produced, and the voice pipeline's
/// own diagnostics log.
struct DiagnosticsSection: View {
    let settings: SettingsStore

    var body: some View {
        Section("Sent Messages") {
            if settings.sentMessages.isEmpty {
                Text("No sent messages yet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            } else {
                ForEach(Array(settings.sentMessages.enumerated()), id: \.offset) { _, message in
                    SentMessageRow(message: message)
                }
            }
        }

        Section("Recordings") {
            if settings.recordings.isEmpty {
                Text("No recordings yet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            } else {
                Text("\(settings.recordings.count) recording(s) saved.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                ForEach(settings.recordings) { recording in
                    RecordingRow(recording: recording)
                }
            }
        }

        VoiceDiagnosticsLogSection()
        LastCrashSection()
    }
}

/// The captured crash launch already presented once — kept here so it can be reread or deleted
/// without interrupting every launch.
private struct LastCrashSection: View {
    @State private var record: CrashRecord?
    @State private var showing: CrashRecord?

    var body: some View {
        Section("Last Crash") {
            if let record {
                Button("View Crash Report") { showing = record }
                    .accessibilityIdentifier("view-last-crash")
                Button("Delete Crash Report", role: .destructive) {
                    CrashReporter.clearLast()
                    self.record = nil
                }
                .accessibilityIdentifier("delete-last-crash")
            } else {
                Text("No crash captured.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
            }
        }
        .onAppear { record = CrashReporter.readLast() }
        .sheet(item: $showing) { crash in
            CrashReportSheet(record: crash)
        }
    }
}

/// A device-test record of the voice pipeline — mode transitions, socket lifecycle, connection
/// health, everything ``VoiceFeedbackNotifier`` and the call-mode state machine log. Present in
/// every build, not only debug ones, since a TestFlight run is exactly what nobody can attach a
/// debugger to. Sharing is the primary path — it works from anywhere, with no session to pick;
/// the composer's own "Past Recordings" sheet offers a second way to attach the same file directly
/// to a message.
private struct VoiceDiagnosticsLogSection: View {
    @State private var sizeBytes = 0
    @State private var shareFile: AttachmentShareFile?

    var body: some View {
        Section {
            LabeledContent("Log size", value: formatFileSize(sizeBytes))
            Button("Share Voice Log") {
                let attachment = AppVoiceDiagnosticsLog.makeAttachment()
                shareFile = AttachmentSharing.stage(attachment.data, filename: attachment.filename)
            }
            .disabled(sizeBytes == 0)
            .accessibilityIdentifier("share-voice-log")
            Button("Clear Voice Log", role: .destructive) {
                AppVoiceDiagnosticsLog.shared.clear()
                refresh()
            }
            .disabled(sizeBytes == 0)
            .accessibilityIdentifier("clear-voice-log")
        } header: {
            Text("Voice Diagnostics Log")
        } footer: {
            Text("What the voice pipeline did on this device — mode changes, connection drops, commands heard.")
        }
        .onAppear(perform: refresh)
        .sheet(item: $shareFile) { file in
            AttachmentShareSheet(activityItems: [file.url])
        }
    }

    private func refresh() {
        sizeBytes = AppVoiceDiagnosticsLog.shared.totalSizeBytes()
    }
}

private struct SentMessageRow: View {
    let message: SentMessage

    @State private var didCopy = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeLabel)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                Text(message.text)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                    .lineLimit(3)
            }

            Spacer()

            Button {
                UIPasteboard.general.string = message.text
                didCopy = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    didCopy = false
                }
            } label: {
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
            }
            .accessibilityIdentifier("copy-sent-message")
        }
    }

    private var timeLabel: String {
        Date(timeIntervalSince1970: message.timestampMs / 1000).formatted(date: .omitted, time: .standard)
    }
}

private struct RecordingRow: View {
    let recording: RecordingMeta

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(timeLabel)
                    .font(PaiTypography.body.font)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Text(durationLabel)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textFaint)
                if recording.endedBy == .crashed {
                    Text("Recovered after the app stopped unexpectedly")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.warningText)
                }
                if let coverageLine {
                    Text(coverageLine)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(
                            recording.transcription?.state == .failed
                                ? PaiPalette.Semantic.errorText : PaiPalette.Semantic.warningText)
                }
            }
        }
    }

    private var timeLabel: String {
        Date(timeIntervalSince1970: recording.timestampMs / 1000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private var durationLabel: String {
        String(format: "%.1fs", recording.durationMs / 1000)
    }

    /// `nil` for a complete take, or one made before the durable pipeline existed — this line is
    /// only worth showing when there is actually something left to say about it.
    private var coverageLine: String? {
        guard let transcription = recording.transcription, transcription.state != .complete else { return nil }
        let totalSeconds = Int(transcription.gapMs / 1000)
        let duration = "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
        return transcription.state == .failed
            ? "Failed to transcribe \(duration)" : "\(duration) untranscribed"
    }
}
