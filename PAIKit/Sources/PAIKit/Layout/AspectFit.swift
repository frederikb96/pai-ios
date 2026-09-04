import Foundation

/// The uniform scale that fits one size into a bounding box without cropping — the same
/// arithmetic `UIContentMode.scaleAspectFit` performs, extracted so a device-only view can be
/// proven without an Apple framework.
///
/// `FullScreenImageViewer`'s pinch-to-zoom (`PAI/Attachments/ZoomableImageView.swift`) uses this
/// to compute the image's starting frame inside a `UIScrollView` — everything past that starting
/// point (the gesture wiring itself) is `UIScrollView`/`UIScrollViewDelegate` and cannot be
/// proven here, but the one piece of arithmetic it depends on can be.
public enum AspectFit {
    /// - Parameters:
    ///   - size: the content's own width and height.
    ///   - bounds: the box it is being fit into.
    /// - Returns: `1` for a degenerate input (either dimension zero or negative) rather than a
    ///   division by zero — the caller is expected to have real, positive sizes on both sides once
    ///   layout has actually happened, and a starting scale of `1` is a harmless default for the
    ///   one frame before that.
    public static func scale(
        fitting size: (width: Double, height: Double), into bounds: (width: Double, height: Double)
    ) -> Double {
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / size.width, bounds.height / size.height)
    }
}
