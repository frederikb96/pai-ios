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

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                ForEach(attachments) { attachment in
                    AttachmentChip(attachment: attachment, onRemove: { onRemove(attachment) })
                }
            }
            .padding(.horizontal, 4)
        }
        .accessibilityIdentifier("attachment-preview-strip")
    }
}

private struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        switch attachment {
        case .staged(let staged): StagedAttachmentChip(attachment: staged, onRemove: onRemove)
        case .remote(let remote): RemoteAttachmentChip(attachment: remote, onRemove: onRemove)
        }
    }
}

private struct StagedAttachmentChip: View {
    let attachment: StagedAttachment
    let onRemove: () -> Void

    /// A failed upload is not a lost file — the bytes are still here and the send carries them
    /// inline. Said out loud anyway, because "this one is only on this phone" is the difference
    /// between a message another device can finish and one it cannot.
    private var uploadNote: (text: String, isProblem: Bool)? {
        switch attachment.uploadState {
        case .uploading: return ("Uploading…", false)
        case .failed: return ("Only on this device", true)
        case .uploaded, .none: return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                removeButton
            }
            if let note = uploadNote {
                Text(note.text)
                    .font(PaiTypography.caption.font)
                    .foregroundStyle(note.isProblem ? PaiPalette.Semantic.errorText : PaiPalette.Semantic.textMuted)
                    .lineLimit(1)
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
            Image(uiImage: previewImage)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
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
        .offset(x: 6, y: -6)
        .accessibilityLabel("Remove file")
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
