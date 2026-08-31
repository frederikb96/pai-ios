import PAIKit
import PhotosUI
import SwiftUI

/// One container's `attachments/` folder: every file, how many links across the container
/// resolve to it, and the ability to add, rename or remove one. Reached from the container list
/// (spec parity with the web's outgoing-links panel, which merges attachment actions into note
/// links — here it gets its own screen instead, since a phone has no docked side panel to fold it
/// into).
struct NoteAttachmentsScreen: View {
    let containerId: String
    let containerName: String

    @Environment(NotesStore.self) private var notes
    @Environment(ToastCenter.self) private var toasts

    @State private var attachments: [NoteAttachmentRecord] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var renameTarget: NoteAttachmentRecord?
    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false

    var body: some View {
        List {
            if let loadError {
                Text(loadError).foregroundStyle(PaiPalette.Semantic.errorText)
            } else if attachments.isEmpty && !isLoading {
                Text("No attachments in this container yet.").foregroundStyle(PaiPalette.Semantic.textMuted)
            } else {
                ForEach(attachments) { attachment in
                    row(for: attachment)
                }
            }
        }
        .listStyle(.plain)
        .paiNotesBackground()
        .navigationTitle(containerName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                PhotosPicker(selection: $photoItem, matching: .images) {
                    if uploading {
                        ProgressView()
                    } else {
                        Image(systemName: "plus")
                    }
                }
                .disabled(uploading)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await upload(item) }
        }
        .sheet(item: $renameTarget) { target in
            NavigationStack {
                RenameAttachmentView(containerId: containerId, attachment: target, notes: notes, toasts: toasts) {
                    renameTarget = nil
                    Task { await reload() }
                }
            }
        }
    }

    @ViewBuilder
    private func row(for attachment: NoteAttachmentRecord) -> some View {
        HStack {
            Image(systemName: isImage(attachment) ? "photo" : "doc")
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.basename)
                    .foregroundStyle(PaiPalette.Semantic.textPrimary)
                Text(
                    "\(formatSize(attachment.sizeBytes)) · \(attachment.linkCount) \(attachment.linkCount == 1 ? "link" : "links")"
                )
                .font(PaiTypography.caption.font)
                .foregroundStyle(PaiPalette.Semantic.textMuted)
            }
        }
        .listRowBackground(PaiPalette.Notes.panelBackground)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                Task { await delete(attachment) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                renameTarget = attachment
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(PaiPalette.primary500)
        }
    }

    private func reload() async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            attachments = try await notes.listAttachments(containerId: containerId)
        } catch {
            loadError = (error as? PaiError)?.userMessage ?? "Could not load attachments"
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        defer {
            uploading = false
            photoItem = nil
        }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            toasts.show("Could not read the selected photo", kind: .error)
            return
        }
        let filename = (item.itemIdentifier ?? UUID().uuidString) + ".jpg"
        do {
            _ = try await notes.uploadAttachment(
                containerId: containerId, filename: filename, mimeType: "image/jpeg", data: data)
            await reload()
        } catch {
            toasts.show((error as? PaiError)?.userMessage ?? "Upload failed", kind: .error)
        }
    }

    private func delete(_ attachment: NoteAttachmentRecord) async {
        do {
            _ = try await notes.deleteAttachment(containerId: containerId, path: attachment.relPath)
            attachments.removeAll { $0.relPath == attachment.relPath }
        } catch {
            toasts.show((error as? PaiError)?.userMessage ?? "Could not delete the attachment", kind: .error)
        }
    }

    private func isImage(_ attachment: NoteAttachmentRecord) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(attachment.ext.lowercased())
    }

    private func formatSize(_ bytes: Int) -> String {
        bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
    }
}

private struct RenameAttachmentView: View {
    let containerId: String
    let attachment: NoteAttachmentRecord
    let notes: NotesStore
    let toasts: ToastCenter
    let onDone: () -> Void

    @State private var name: String
    @State private var isSaving = false

    init(
        containerId: String, attachment: NoteAttachmentRecord, notes: NotesStore, toasts: ToastCenter,
        onDone: @escaping () -> Void
    ) {
        self.containerId = containerId
        self.attachment = attachment
        self.notes = notes
        self.toasts = toasts
        self.onDone = onDone
        _name = State(initialValue: attachment.basename)
    }

    var body: some View {
        Form {
            TextField("File name", text: $name)
        }
        .navigationTitle("Rename attachment")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSaving)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // `relPath` is container-root-relative, e.g. `attachments/x.png` — keep the directory,
        // rename only the last path component.
        let lastSlash = attachment.relPath.lastIndex(of: "/")
        let toPath = lastSlash.map { String(attachment.relPath[..<$0]) + "/" + trimmed } ?? trimmed
        do {
            _ = try await notes.renameAttachment(containerId: containerId, fromPath: attachment.relPath, toPath: toPath)
            onDone()
        } catch {
            toasts.show((error as? PaiError)?.userMessage ?? "Could not rename the attachment", kind: .error)
        }
    }
}
