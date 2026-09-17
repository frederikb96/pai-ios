import PAIKit
import SwiftUI

/// Records real "Computer" utterances (and, in negative mode, other speech or ambient noise)
/// through this phone's own microphone — training data for retraining the offline wake-word
/// classifier on Freddy's own voice and microphones, mixed into the synthetic-TTS corpus
/// `Tooling/wakeword` already trains from. Reachable from Settings, near the other voice and call
/// settings.
///
/// The whole point is speed: tap Start, say "Computer", tap Next — which begins the next take
/// immediately — say it again, and so on, repeating the run in a different voice or with a
/// different microphone connected. Samples accumulate here across as many runs as Freddy likes;
/// nothing is capped or evicted automatically (`WakeWordSampleStore`'s own doc comment) — Export,
/// then Clear All, is how a finished batch actually leaves the device.
struct WakeWordSampleScreen: View {
    let controller: WakeWordSampleCaptureController
    let store: WakeWordSampleStore

    @State private var kind: WakeWordSample.Kind = .positive
    @State private var confirmingClearAll = false
    @State private var label = ""
    @State private var errorMessage: String?
    @State private var exportBundle: ExportBundle?

    private let audioStorage = WakeWordSampleAudioStorage()

    var body: some View {
        Form {
            recordSection
            samplesSection
            if !store.samples.isEmpty {
                sampleListSection
            }
        }
        .paiListBackground()
        .navigationTitle("Wake Word Samples")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't export samples", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $exportBundle) { bundle in
            AttachmentShareSheet(activityItems: bundle.urls)
        }
        .accessibilityIdentifier("wake-word-sample-screen")
    }

    /// While a run is active, the kind/label shown are the controller's own `runKind`/`runLabel`
    /// — never this view's local `$kind`/`$label` — because the controller is app-wide and
    /// outlives this screen (`WakeWordSampleCaptureController`'s own doc comment): navigating
    /// away mid-run and back must show what is actually recording, not whatever this view's own
    /// state happened to reset to.
    private var recordSection: some View {
        Section {
            if controller.isRunning {
                LabeledContent("Kind", value: controller.runKind == .positive ? "Positive" : "Negative")
                if let runLabel = controller.runLabel, !runLabel.isEmpty {
                    LabeledContent("Label", value: runLabel)
                }
                LabeledContent("Take", value: "#\(controller.currentTakeIndex ?? 1)")
                Button("Next") { controller.next() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("wake-word-sample-next")
                Button("Stop", role: .destructive) { controller.stopRun() }
                    .accessibilityIdentifier("wake-word-sample-stop")
            } else {
                Picker("Kind", selection: $kind) {
                    Text("Positive — says \"Computer\"").tag(WakeWordSample.Kind.positive)
                    Text("Negative — other speech/noise").tag(WakeWordSample.Kind.negative)
                }
                .accessibilityIdentifier("wake-word-sample-kind")

                TextField("Label — e.g. loud windy, AirPods", text: $label)
                    .accessibilityIdentifier("wake-word-sample-label")

                Button("Start") { Task { await controller.startRun(kind: kind, label: label) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStart)
                    .accessibilityIdentifier("wake-word-sample-start")
            }

            if let failure = controller.startFailure {
                Text(failure.userMessage)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
            }
            if let reason = controller.lastRunEndReason {
                Text(reason.userMessage)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
            }
        } header: {
            Text("Record")
        } footer: {
            Text("Say it, tap Next, say it again — the next take starts the instant you tap.")
        }
    }

    private var samplesSection: some View {
        Section {
            storageHeaderLine
            Button("Export All (\(store.samples.count))") { export() }
                .disabled(store.samples.isEmpty)
                .accessibilityIdentifier("wake-word-sample-export")
            Button("Clear All", role: .destructive) { confirmingClearAll = true }
                .disabled(store.samples.isEmpty)
                .accessibilityIdentifier("wake-word-sample-clear-all")
                .confirmationDialog(
                    "Delete all \(store.samples.count) recordings?", isPresented: $confirmingClearAll,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) { store.clearAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("They exist only on this phone. Export them first if they are not handed over yet.")
                }
        } header: {
            Text("Samples")
        } footer: {
            Text("Export before Clear All — clearing deletes the audio on this device for good.")
        }
    }

    private var sampleListSection: some View {
        Section {
            ForEach(store.samples.reversed()) { sample in
                WakeWordSampleRow(sample: sample)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            store.remove(id: sample.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    private var storageHeaderLine: some View {
        let usedMB = Double(audioStorage.totalBytesUsed()) / 1_000_000
        return Text("\(store.samples.count) sample(s) · \(String(format: "%.1f", usedMB)) MB")
            .font(PaiTypography.caption.font)
            .foregroundStyle(PaiPalette.Semantic.textMuted)
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    /// Stages every current sample's WAV plus a manifest.json into fresh temp files and hands
    /// them to the iOS share sheet as one multi-item share — "Save to Files" lets Freddy pick a
    /// folder and drops every file into it, AirDrop and Mail send them all together. A single
    /// zip would be tidier, but iOS has no public API to build one and this needs no dependency
    /// to reach the same outcome: a folder of WAVs plus the manifest describing them.
    private func export() {
        var urls: [URL] = []
        for sample in store.samples {
            guard let data = audioStorage.load(fileName: sample.fileName),
                let staged = AttachmentSharing.stage(data, filename: sample.fileName)
            else { continue }
            urls.append(staged.url)
        }
        if let manifestData = try? WakeWordSampleManifest.encode(store.samples),
            let staged = AttachmentSharing.stage(manifestData, filename: "wake-word-samples-manifest.json")
        {
            urls.append(staged.url)
        }
        guard !urls.isEmpty else {
            errorMessage = "No samples to export yet."
            return
        }
        exportBundle = ExportBundle(urls: urls)
    }
}

/// `AttachmentShareSheet` presents one file's `AttachmentShareFile`; this screen shares several at
/// once, so it needs its own `Identifiable` wrapper around the whole batch rather than one per
/// file.
private struct ExportBundle: Identifiable {
    let id = UUID()
    let urls: [URL]
}

private struct WakeWordSampleRow: View {
    let sample: WakeWordSample

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(kindLabel)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(
                        sample.kind == .positive ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textMuted)
                if !sample.label.isEmpty {
                    Text(sample.label)
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                }
            }
            Text(headline)
                .font(PaiTypography.bodyEmphasized.font)
            Text(detailLine)
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
        }
    }

    private var kindLabel: String {
        sample.kind == .positive ? "Positive" : "Negative"
    }

    private var headline: String {
        let date = Date(timeIntervalSince1970: sample.recordedAtMs / 1000)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        return "\(formatter.string(from: date)) · \(String(format: "%.1f", sample.durationMs / 1000))s"
    }

    private var detailLine: String {
        "\(sample.microphoneRoute) · \(sample.sampleRate / 1000) kHz"
    }
}
