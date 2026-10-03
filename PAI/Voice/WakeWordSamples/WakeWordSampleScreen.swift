import PAIKit
import SwiftUI

/// Records wake-word samples for tuning or retraining the "computer" classifier: tap Start, say
/// the word, tap Next — which opens the next take at once — say it again, and so on. A run is one
/// kind (the wake word, or other words it must not fire on) under one label for the microphone;
/// a new microphone is a new run.
///
/// Every take goes to the backend as soon as it closes, or as soon as the phone is back online;
/// the list below is what the backend holds plus what is still on its way up. Deleting here
/// deletes there.
struct WakeWordSampleScreen: View {
    let controller: WakeWordSampleCaptureController

    @State private var kind: WakeWordSampleKind = .positive
    @State private var label = VoiceDevice.currentMicrophone ?? ""

    var body: some View {
        Form {
            recordSection
            runsSection
        }
        .paiListBackground()
        .navigationTitle("Wake-word Samples")
        .navigationBarTitleDisplayMode(.inline)
        .task { await controller.refresh() }
        .refreshable { controller.drain() }
        .accessibilityIdentifier("wake-word-sample-screen")
    }

    /// While a run is going, what is shown is the controller's own kind and label — it outlives
    /// this screen, so coming back mid-run must show what is actually recording.
    private var recordSection: some View {
        Section {
            if controller.isRunning {
                LabeledContent("Kind", value: controller.runKind.map(kindTitle) ?? "")
                if let runLabel = controller.runLabel, !runLabel.isEmpty {
                    LabeledContent("Microphone", value: runLabel)
                }
                LabeledContent("Take", value: "#\(controller.currentTakeIndex ?? 1)")
                Button("Next") { controller.next() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("wake-word-sample-next")
                Button("Stop", role: .destructive) { controller.stopRun() }
                    .accessibilityIdentifier("wake-word-sample-stop")
            } else {
                Picker("Kind", selection: $kind) {
                    Text(kindTitle(.positive)).tag(WakeWordSampleKind.positive)
                    Text(kindTitle(.negative)).tag(WakeWordSampleKind.negative)
                }
                .accessibilityIdentifier("wake-word-sample-kind")
                TextField("Microphone — e.g. AirPods, phone, car", text: $label)
                    .accessibilityIdentifier("wake-word-sample-label")
                Button("Start") {
                    Task { await controller.startRun(kind: kind, label: label.trimmingCharacters(in: .whitespaces)) }
                }
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

    private var runsSection: some View {
        Section {
            ForEach(rows) { row in
                WakeWordRunRow(row: row, kindTitle: kindTitle(row.kind))
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await controller.deleteRun(id: row.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
            if rows.isEmpty {
                Text("No runs yet.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            if let error = controller.listError ?? controller.queue.lastError {
                Text(error)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.warningText)
            }
        } header: {
            Text("Runs")
        } footer: {
            Text("Kept on the server until deleted, here or on the web.")
        }
    }

    /// The backend's runs plus whatever is still queued here, newest first. A run partly up shows
    /// its stored takes plus how many are still waiting.
    private var rows: [WakeWordRunRowModel] {
        var result: [WakeWordRunRowModel] = []
        for stored in controller.storedRuns {
            let pending = controller.queue.runs.first { $0.id == stored.id }
            result.append(
                WakeWordRunRowModel(
                    id: stored.id, kind: WakeWordSampleKind(rawValue: stored.kind) ?? .negative, label: stored.label,
                    mic: stored.mic, createdAt: stored.createdAt, storedTakes: stored.takes.count,
                    pendingTakes: pending?.takes.count ?? 0))
        }
        for pending in controller.queue.runs where !controller.storedRuns.contains(where: { $0.id == pending.id }) {
            result.append(
                WakeWordRunRowModel(
                    id: pending.id, kind: pending.upload.kind, label: pending.upload.label, mic: pending.upload.mic,
                    createdAt: pending.upload.createdAt, storedTakes: 0, pendingTakes: pending.takes.count))
        }
        return result.sorted { $0.createdAt > $1.createdAt }
    }

    private func kindTitle(_ kind: WakeWordSampleKind) -> String {
        switch kind {
        case .positive: "Positive — says “Computer”"
        case .negative: "Negative — other words"
        }
    }
}

private struct WakeWordRunRowModel: Identifiable {
    let id: String
    let kind: WakeWordSampleKind
    let label: String
    let mic: String?
    let createdAt: String
    let storedTakes: Int
    let pendingTakes: Int
}

private struct WakeWordRunRow: View {
    let row: WakeWordRunRowModel
    let kindTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kindTitle)
                .font(PaiTypography.caption.font)
                .foregroundStyle(
                    row.kind == .positive ? PaiPalette.Semantic.accentText : PaiPalette.Semantic.textMuted)
            Text(headline)
                .font(PaiTypography.bodyEmphasized.font)
            Text(detail)
                .font(PaiTypography.caption.font)
                .foregroundStyle(row.pendingTakes > 0 ? PaiPalette.Semantic.warningText : PaiPalette.Semantic.textFaint)
        }
    }

    private var headline: String {
        let date = IsoTimestamp.date(from: row.createdAt).map {
            $0.formatted(date: .abbreviated, time: .shortened)
        }
        return [date, row.label.isEmpty ? nil : row.label].compactMap { $0 }.joined(separator: " · ")
    }

    private var detail: String {
        var parts = ["\(row.storedTakes) uploaded"]
        if row.pendingTakes > 0 { parts.append("\(row.pendingTakes) waiting to upload") }
        if let mic = row.mic, mic != row.label { parts.append(mic) }
        return parts.joined(separator: " · ")
    }
}
