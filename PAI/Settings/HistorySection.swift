import PAIKit
import SwiftUI
import UIKit

/// What this device has produced: the takes it recorded, the messages it sent, and what the
/// voice pipeline logged doing it.
///
/// Three doors, not three lists. Each opens the real view — the same `RecordingsSheet` the
/// composer's own plus menu opens, so there is one place per thing rather than a working view
/// behind a composer and a read-only copy of it here.
struct HistorySection: View {
    let settings: SettingsStore
    @Environment(AppEnvironment.self) private var environment

    /// `nil` only between sign-out and a fresh sign-in, when this screen is not reachable
    /// anyway — the same defensive read `VoiceSection` makes of the same optional.
    private var voice: VoiceRecorderController? { environment.connection?.voice }

    @State private var showingRecordings = false
    @State private var showingSentMessages = false
    @State private var showingVoiceLog = false

    var body: some View {
        Section {
            if let voice {
                Button {
                    showingRecordings = true
                } label: {
                    LabeledContent("Past Recordings", value: "\(settings.recordings.count)")
                }
                .accessibilityIdentifier("open-recordings")
                .sheet(isPresented: $showingRecordings) {
                    // No composer behind this screen, so no insert and no attach — the sheet
                    // draws neither when they are absent.
                    RecordingsSheet(controller: voice)
                }
            }

            Button {
                showingSentMessages = true
            } label: {
                LabeledContent("Past Messages", value: "\(settings.sentMessages.count)")
            }
            .accessibilityIdentifier("open-sent-messages")
            .sheet(isPresented: $showingSentMessages) {
                SentMessagesSheet(settings: settings)
            }

            Button("Voice Diagnostics Log") { showingVoiceLog = true }
                .accessibilityIdentifier("open-voice-log")
                .sheet(isPresented: $showingVoiceLog) {
                    VoiceDiagnosticsLogSheet()
                }
        } header: {
            Text("History")
        } footer: {
            Text("Recordings and sent messages are kept on this device only, ten of each.")
        }
    }
}

/// The last messages this device sent, with the copy button each row has always had — a
/// recovery aid for one that did not land.
struct SentMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let settings: SettingsStore

    var body: some View {
        NavigationStack {
            Group {
                if settings.sentMessages.isEmpty {
                    ContentUnavailableView(
                        "No sent messages yet", systemImage: "text.bubble",
                        description: Text("Messages you send from this device are kept here.")
                    )
                } else {
                    List {
                        ForEach(Array(settings.sentMessages.enumerated()), id: \.offset) { _, message in
                            SentMessageRow(message: message)
                        }
                    }
                }
            }
            .navigationTitle("Past Messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .accessibilityIdentifier("sent-messages-sheet")
    }
}

/// A device-test record of the voice pipeline — mode transitions, socket lifecycle, connection
/// health, everything ``VoiceFeedbackNotifier`` and the call-mode state machine log. Present in
/// every build, not only debug ones, since a TestFlight run is exactly what nobody can attach a
/// debugger to. Sharing is the path from here — it works with no session to pick; the
/// composer's own Past Recordings sheet attaches the same file directly to a message instead.
struct VoiceDiagnosticsLogSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var sizeBytes = 0
    @State private var shareFile: AttachmentShareFile?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Log size", value: formatFileSize(sizeBytes))
                    Button("Share Voice Log") {
                        let attachment = AppVoiceDiagnosticsLog.makeAttachment()
                        shareFile = AttachmentSharing.stage(
                            attachment.data, filename: attachment.filename)
                    }
                    .disabled(sizeBytes == 0)
                    .accessibilityIdentifier("share-voice-log")
                    Button("Clear Voice Log", role: .destructive) {
                        AppVoiceDiagnosticsLog.shared.clear()
                        refresh()
                    }
                    .disabled(sizeBytes == 0)
                    .accessibilityIdentifier("clear-voice-log")
                } footer: {
                    Text(
                        "What the voice pipeline did on this device — mode changes, connection drops, commands heard."
                    )
                }
            }
            .paiListBackground()
            .navigationTitle("Voice Diagnostics Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
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

struct SentMessageRow: View {
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
                    .lineLimit(4)
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
            .buttonStyle(.borderless)
            .accessibilityIdentifier("copy-sent-message")
        }
    }

    private var timeLabel: String {
        Date(timeIntervalSince1970: message.timestampMs / 1000)
            .formatted(date: .abbreviated, time: .standard)
    }
}
