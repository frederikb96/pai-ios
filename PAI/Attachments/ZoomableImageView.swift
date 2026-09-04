import PAIKit
import SwiftUI
import UIKit

/// Pinch-to-zoom, double-tap-to-zoom and panning for a full-screen image, matching Photos.
///
/// A SwiftUI `MagnificationGesture` was the other option and was rejected: it has no equivalent
/// to `UIScrollView`'s own rubber-banding at the zoom limits, no separate double-tap target
/// scale, and no built-in interplay between "pan to scroll a zoomed image" and "the enclosing
/// screen's own swipe-to-dismiss" the way `UIScrollView`'s pan recognizer gives one for free.
/// This reaches for the same primitive Photos itself is built on instead.
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// Mirrors the scroll view's live zoom scale out to the caller — `FullScreenImageViewer`'s
    /// swipe-to-dismiss only makes sense at rest scale, exactly as in Photos: once zoomed in, a
    /// downward drag pans the image rather than dismissing the screen.
    @Binding var zoomScale: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomScale: $zoomScale)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = ZoomableScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        scrollView.imageView = imageView
        context.coordinator.scrollView = scrollView

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        return scrollView
    }

    /// Nothing to push down: the image itself never changes for a presented viewer, and the
    /// scroll view's own `layoutSubviews` (`ZoomableScrollView`) is what reacts to a bounds
    /// change such as a rotation. A representable's `updateUIView` fires on SwiftUI state
    /// changes, which a device rotation is not one of.
    func updateUIView(_ uiView: UIScrollView, context: Context) {}

    final class Coordinator: NSObject, UIScrollViewDelegate {
        @Binding private var zoomScale: CGFloat
        // `fileprivate`, not the implicit `internal` a nested type's member defaults to — the
        // Linux-invisible compile error this fixes only ever surfaces on a Mac build:
        // `ZoomableScrollView` is `private` (file-scoped), so a member whose type IS that private
        // type cannot itself be wider than fileprivate access.
        fileprivate weak var scrollView: ZoomableScrollView?

        init(zoomScale: Binding<CGFloat>) {
            _zoomScale = zoomScale
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            (scrollView as? ZoomableScrollView)?.imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomableScrollView)?.centerImage()
            zoomScale = scrollView.zoomScale
        }

        /// Zooms toward the tapped point rather than always toward the centre, matching Photos —
        /// a double-tap near an edge that zoomed to the middle would put the thing just tapped on
        /// off-screen.
        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let point = recognizer.location(in: scrollView.imageView)
            let target = scrollView.maximumZoomScale
            let size = CGSize(width: scrollView.bounds.width / target, height: scrollView.bounds.height / target)
            let origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
            scrollView.zoom(to: CGRect(origin: origin, size: size), animated: true)
        }
    }
}

/// Fits its image view to the current bounds on first layout and again on every bounds size
/// change (a rotation), preserving whatever zoom is in progress otherwise.
///
/// `UIScrollViewDelegate` has no "did lay out" callback, so this is done in `layoutSubviews`
/// itself — guarded by whether the scroll view's own `bounds` actually changed size, rather than
/// re-fitting on every call, since zooming changes `contentSize`/`contentOffset` and triggers a
/// layout pass without `bounds` itself changing.
private final class ZoomableScrollView: UIScrollView {
    weak var imageView: UIImageView?
    private var lastBoundsSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView, let image = imageView.image, bounds.width > 0, bounds.height > 0 else { return }

        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            let scale = AspectFit.scale(
                fitting: (width: image.size.width, height: image.size.height),
                into: (width: bounds.width, height: bounds.height)
            )
            let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            imageView.frame = CGRect(origin: .zero, size: fitted)
            contentSize = fitted
            zoomScale = 1
        }
        centerImage()
    }

    /// A zoomed-out image is smaller than the scroll view's own bounds on one or both axes —
    /// `UIScrollView` does not centre its content itself, it pins to the top-left, which is
    /// exactly why the classic Apple `PhotoScroller` sample recentres this way on every zoom.
    func centerImage() {
        guard let imageView else { return }
        var frame = imageView.frame
        frame.origin.x = frame.width < bounds.width ? (bounds.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < bounds.height ? (bounds.height - frame.height) / 2 : 0
        imageView.frame = frame
    }
}
