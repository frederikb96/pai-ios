import PAIKit
import SwiftUI
import UIKit

/// The attachments waiting on the owner for one shared note: files the note links to that visitors
/// cannot see yet (outgoing), and uploads visitors made that are not in the vault yet (incoming).
/// Nothing crosses between the two sides without a tap here.
///
/// "Publish all" leaves out a file a visitor's edit introduced and a file too large to publish —
/// naming a file in the body is not a reason to expose it, so each of those needs its own tap with
/// the name in front of the owner. Swift port of the web's `ShareQueues`.
struct NoteShareQueueScreen: View {
    let store: NoteShareStore
    let toasts: ToastCenter

    @State private var confirmingPublishAll = false
    @State private var confirmingDiscardAll = false

    var body: some View {
        List {
            if let error = store.errorMessage {
                Section {
                    Text(error).foregroundStyle(PaiPalette.Semantic.errorText)
                }
            }
            outgoingSection
            incomingSection
        }
        .navigationTitle("Attachments waiting")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
        .disabled(store.isBusy)
        .confirmationDialog(
            "Publish \(store.publishAllCandidates.count) files?", isPresented: $confirmingPublishAll,
            titleVisibility: .visible
        ) {
            Button("Publish") { perform("Published") { await store.publishAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(publishAllMessage)
        }
        .confirmationDialog(
            "Discard every waiting upload?", isPresented: $confirmingDiscardAll, titleVisibility: .visible
        ) {
            Button("Discard all", role: .destructive) { perform("Discarded") { await store.discardAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They are removed from the shared copy and never reach the vault.")
        }
    }

    // MARK: Outgoing

    @ViewBuilder
    private var outgoingSection: some View {
        let outgoing = store.share?.outgoing ?? []
        Section {
            if outgoing.isEmpty {
                Text("Every file this note links to is already visible to link holders.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            ForEach(outgoing) { item in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(item.name).foregroundStyle(PaiPalette.Semantic.textPrimary)
                        Spacer()
                        Button("Publish") { perform("Published") { await store.publish([item.relPath]) } }
                            .buttonStyle(.bordered)
                            .disabled(item.tooLarge)
                    }
                    Text(detailLine(for: item))
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textMuted)
                    if item.requestedByVisitor {
                        Label("A visitor's edit linked this file", systemImage: "exclamationmark.triangle")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.warningText)
                    }
                    if item.tooLarge {
                        Text("Too large to publish.")
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.errorText)
                    }
                }
            }
            if !store.publishAllCandidates.isEmpty {
                Button("Publish all (\(store.publishAllCandidates.count))") { confirmingPublishAll = true }
            }
        } header: {
            Text("Outgoing — not visible to visitors yet")
        } footer: {
            if store.heldBackFromPublishAll > 0 {
                Text(
                    "\(store.heldBackFromPublishAll) held back from \u{201c}Publish all\u{201d}: they need their own tap."
                )
            }
        }
    }

    private var publishAllMessage: String {
        let names = store.publishAllCandidates.map(\.name).joined(separator: ", ")
        let held = store.heldBackFromPublishAll
        return held > 0 ? "\(names)\n\n\(held) more are held back and need their own tap." : names
    }

    private func detailLine(for item: NoteShareOutgoing) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file)
        return "\(item.reason == "changed" ? "Changed in the vault" : "New") · \(size)"
    }

    // MARK: Incoming

    @ViewBuilder
    private var incomingSection: some View {
        let incoming = store.share?.incoming ?? []
        Section {
            if incoming.isEmpty {
                Text("No uploads waiting.")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
            ForEach(incoming) { blob in
                VStack(alignment: .leading, spacing: 8) {
                    Text(blob.name).foregroundStyle(PaiPalette.Semantic.textPrimary)
                    Text(
                        "\(blob.contentType) · \(ByteCountFormatter.string(fromByteCount: Int64(blob.sizeBytes), countStyle: .file))"
                    )
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    ShareBlobPreview(blob: blob, store: store)
                    HStack {
                        Button("Accept") { perform("Accepted") { await store.accept([blob.id]) } }
                            .buttonStyle(.borderedProminent)
                        Button("Discard", role: .destructive) {
                            perform("Discarded") { await store.discard([blob.id]) }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
            if incoming.count > 1 {
                Button("Accept all (\(incoming.count))") { perform("Accepted") { await store.acceptAll() } }
                Button("Discard all", role: .destructive) { confirmingDiscardAll = true }
            }
        } header: {
            Text("Incoming — uploaded by visitors")
        } footer: {
            Text("Accepting writes the file into the vault under the name shown. Only raster images are previewed.")
        }
    }

    /// Runs one queue action. The store reports a partial failure through its own `errorMessage`,
    /// shown at the top; a toast is only the confirmation of a clean run.
    private func perform(_ confirmation: String, _ action: @escaping () async -> Bool) {
        Task {
            if await action() { toasts.show(confirmation) }
        }
    }
}

/// An incoming upload's picture, fetched with the owner's credential and drawn only for the
/// raster types `NoteShareBlob.isPreviewableImage` allows.
private struct ShareBlobPreview: View {
    let blob: NoteShareBlob
    let store: NoteShareStore

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        if blob.isPreviewableImage {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else if failed {
                    Text("Preview unavailable")
                        .font(PaiTypography.caption.font)
                        .foregroundStyle(PaiPalette.Semantic.textFaint)
                } else {
                    ProgressView()
                }
            }
            .task(id: blob.id) {
                guard let data = await store.attachmentData(blobId: blob.id), let decoded = UIImage(data: data)
                else {
                    failed = true
                    return
                }
                image = decoded
            }
        } else {
            Text("No preview for this file type.")
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textFaint)
        }
    }
}
