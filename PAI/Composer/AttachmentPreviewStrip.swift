import PAIKit
import SwiftUI

/// Either half of what can sit in the strip: a file this device staged (bytes in hand, maybe
/// still uploading), or one another device already put on the draft — visible here, but with no
/// bytes to preview, since a remote-only attachment's data was never downloaded to this device.
enum ComposerAttachment: Identifiable {
    case staged(StagedAttachment)
    case remote(DraftAttachment)

    var id: String {
        switch self {
        case .staged(let attachment): return attachment.id.uuidString
        case .remote(let attachment): return attachment.id
        }
    }
}

/// The staged-attachment strip above the text field. Every remove affordance is always visible —
/// the web's `X` only appears on hover, which has no touch equivalent, so this deliberately
/// diverges rather than hiding the only way to undo a pick.
struct AttachmentPreviewStrip: View {
    let attachments: [ComposerAttachment]
    let onRemove: (ComposerAttachment) -> Void
    var onRetry: (ComposerAttachment) -> Void = { _ in }

    @State private var showingAll = false

    private var hiddenCount: Int {
        AttachmentListBound.hiddenCount(total: attachments.count, limit: AttachmentListBound.composerVisible)
    }

    /// Any number of files can be attached; the strip draws a few and a "+N" tile opens the rest,
    /// so the composer stays one row tall however many there are.
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments.prefix(AttachmentListBound.composerVisible)) { attachment in
                    chip(attachment)
                }
                if hiddenCount > 0 {
                    Button {
                        showingAll = true
                    } label: {
                        Text("+\(hiddenCount)")
                            .font(PaiTypography.caption.font)
                            .frame(width: 64, height: 64)
                            .background(PaiPalette.Semantic.raisedSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show all \(attachments.count) attachments")
                    .accessibilityIdentifier("attachment-more")
                }
            }
            .padding(.horizontal, 4)
        }
        .accessibilityIdentifier("attachment-preview-strip")
        .sheet(isPresented: $showingAll) {
            NavigationStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12, alignment: .top)], spacing: 16) {
                        ForEach(attachments) { attachment in
                            chip(attachment)
                        }
                    }
                    .padding()
                }
                .navigationTitle("Attachments (\(attachments.count))")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingAll = false }
                    }
                }
            }
        }
        // Removals can bring the count back inside the strip; the sheet has nothing left to list.
        .onChange(of: hiddenCount) { _, hidden in
            if hidden == 0 { showingAll = false }
        }
    }

    private func chip(_ attachment: ComposerAttachment) -> some View {
        AttachmentChip(
            attachment: attachment, onRemove: { onRemove(attachment) }, onRetry: { onRetry(attachment) })
    }
}

private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch attachment {
        case .staged(let staged): StagedAttachmentChip(attachment: staged, onRemove: onRemove, onRetry: onRetry)
        case .remote(let remote): RemoteAttachmentChip(attachment: remote, onRemove: onRemove)
        }
    }
}

private struct StagedAttachmentChip: View {
    let attachment: StagedAttachment
    let onRemove: () -> Void
    let onRetry: () -> Void

    /// A failed upload is not a lost file — the bytes are still here and the send carries them
    /// inline. Said out loud anyway, because "this one is only on this phone" is the difference
    /// between a message another device can finish and one it cannot.
    private var uploadNote: (text: String, isProblem: Bool)? {
        switch attachment.uploadState {
        case .uploading: return ("Uploading…", false)
        case .failed: return ("Upload failed — sent inline otherwise", true)
        case .uploaded, .none: return nil
        }
    }

    private var showsRetry: Bool { attachment.uploadState == .failed }

    @State private var fullScreenTarget: FullScreenImageTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                HStack(spacing: 4) {
                    if showsRetry { retryButton }
                    removeButton
                }
                .offset(x: 6, y: -6)
            }
            if let note = uploadNote {
                Text(note.text)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(note.isProblem ? PaiPalette.Semantic.errorText : PaiPalette.Semantic.textMuted)
                    .lineLimit(2)
            }
            if attachment.wasCompressed {
                Text("\(formatFileSize(attachment.originalSize)) → \(formatFileSize(attachment.currentSize))")
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: 120)
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let previewImage = attachment.previewImage {
            // The shared full-screen viewer, shown the bytes that will be sent rather than the
            // thumbnail's own decode.
            Button {
                fullScreenTarget = FullScreenImageTarget(
                    image: UIImage(data: attachment.data) ?? previewImage, filename: attachment.filename)
            } label: {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View \(attachment.filename)")
            .fullScreenImageViewer($fullScreenTarget)
        } else {
            HStack(spacing: 4) {
                Image(systemName: "doc")
                Text(attachment.filename)
                    .font(PaiTypography.caption.font)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
            .frame(width: 120, height: 64, alignment: .leading)
            .background(PaiPalette.Semantic.raisedSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.white, .black.opacity(0.6))
                .font(.system(size: 18))
        }
        .accessibilityLabel("Remove file")
    }

    private var retryButton: some View {
        Button(action: onRetry) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.white, PaiPalette.primary500)
                .font(.system(size: 18))
        }
        .accessibilityLabel("Retry upload")
    }
}

/// A file another device put on this draft. No thumbnail — its bytes were never downloaded here
/// — just what the server knows: name and size, plus a glyph marking it as arriving from
/// elsewhere rather than something this device is about to upload itself.
private struct RemoteAttachmentChip: View {
    let attachment: DraftAttachment
    let onRemove: () -> Void

    /// `unclaimed` is the backend saying a message has already gone without this file. Drawn
    /// identically to a healthy row, the only thing that ever said so was the chip refusing to
    /// disappear — minutes after the message had sent.
    private var problem: String? {
        guard attachment.needsAttention else { return nil }
        return attachment.state == "unclaimed"
            ? "Last message went without this"
            : "Never reached the server"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    Image(systemName: problem == nil ? "icloud.and.arrow.down" : "exclamationmark.icloud")
                    VStack(alignment: .leading, spacing: 0) {
                        Text(attachment.filename)
                            .font(PaiTypography.caption.font)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(formatFileSize(attachment.size))
                            .font(PaiTypography.caption.font)
                            .foregroundStyle(PaiPalette.Semantic.textMuted)
                    }
                }
                .padding(8)
                .frame(width: 120, height: 64, alignment: .leading)
                .background(PaiPalette.Semantic.raisedSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.system(size: 18))
                }
                .offset(x: 6, y: -6)
                .accessibilityLabel("Remove file")
            }
            if let problem {
                Text(problem)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(PaiPalette.Semantic.errorText)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 120)
    }
}
