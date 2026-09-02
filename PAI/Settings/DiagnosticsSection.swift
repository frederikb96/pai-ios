import PAIKit
import SwiftUI
import UIKit

/// The two read-only diagnostic lists at the bottom of the panel — a recovery aid for a message
/// that did not land, and a record of what voice capture produced, not settings themselves.
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
}
