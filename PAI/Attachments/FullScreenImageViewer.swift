import SwiftUI

/// One image, shown full-screen — the single viewer every image tap in the app opens, whether
/// it came from a session attachment, a `pai-file:` marker, or a note's own embed.
///
/// Unlike the web's version, this carries a share button rather than relying on a long-press:
/// Freddy asked for it explicitly, since the web's "the browser's own right-click already gives
/// copy and save" has no equivalent gesture affordance on a touchscreen.
struct FullScreenImageViewer: View {
    let image: UIImage
    let filename: String

    @Environment(\.dismiss) private var dismiss
    @State private var isSharing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .padding()
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 16) {
                Button {
                    isSharing = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.title3)
                }
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.title3)
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
        .sheet(isPresented: $isSharing) {
            AttachmentShareSheet(activityItems: [image])
        }
        // A swipe down is the platform's own dismiss gesture for a full-screen presentation —
        // tapping the image itself does nothing, matching the web's "outside the image, never on
        // it" rule, translated to the one gesture iOS already gives a modal for free.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    if value.translation.height > 80 { dismiss() }
                }
        )
    }
}

/// What ``FullScreenImageViewer`` needs to be presented as a `.fullScreenCover(item:)` — one
/// value per presentation, so tapping a second image while the first is still loading (unlikely,
/// but the type should not assume it cannot happen) opens a fresh cover rather than mutating one
/// already on screen.
struct FullScreenImageTarget: Identifiable {
    let id = UUID()
    let image: UIImage
    let filename: String
}

extension View {
    /// See ``FullScreenImageViewer``.
    func fullScreenImageViewer(_ target: Binding<FullScreenImageTarget?>) -> some View {
        fullScreenCover(item: target) { value in
            FullScreenImageViewer(image: value.image, filename: value.filename)
        }
    }
}
