import PAIKit
import SwiftUI

/// The staged-attachment strip above the text field. Every remove affordance is always visible —
/// the web's `X` only appears on hover, which has no touch equivalent, so this deliberately
/// diverges rather than hiding the only way to undo a pick.
struct AttachmentPreviewStrip: View {
    let attachments: [StagedAttachment]
    let onRemove: (StagedAttachment) -> Void

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
    let attachment: StagedAttachment
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                removeButton
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
