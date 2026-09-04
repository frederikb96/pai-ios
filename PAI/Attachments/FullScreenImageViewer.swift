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
    @State private var zoomScale: CGFloat = 1

    /// How close to the resting scale still counts as "not zoomed" for the swipe-to-dismiss gate
    /// below — `UIScrollView` settles fractionally off `1.0` after its own rubber-band animation,
    /// so an exact-equality check would leave the gesture permanently disabled after the first
    /// pinch.
    private static let restScaleTolerance: CGFloat = 1.01

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZoomableImageView(image: image, zoomScale: $zoomScale)
                .ignoresSafeArea()
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
            .padding(10)
            // A plain icon straight over the image is illegible against a light or busy region of
            // it — the same class of "foreground content with nothing behind it to guarantee
            // contrast" as the sign-in card's own bug, just with the roles of foreground and
            // background swapped. A material scrim guarantees legibility regardless of what is
            // under it, the way Photos' own toolbar does, without needing a fixed opaque colour
            // that would look wrong in light mode.
            .background(.thinMaterial, in: Capsule())
            .padding()
        }
        .sheet(isPresented: $isSharing) {
            AttachmentShareSheet(activityItems: [image])
        }
        // A swipe down is the platform's own dismiss gesture for a full-screen presentation —
        // tapping the image itself does nothing, matching the web's "outside the image, never on
        // it" rule, translated to the one gesture iOS already gives a modal for free. Gated on
        // resting scale, matching Photos: once zoomed in, a downward drag pans the image inside
        // its `UIScrollView` instead of dismissing the screen.
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { value in
                    guard zoomScale <= Self.restScaleTolerance else { return }
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
