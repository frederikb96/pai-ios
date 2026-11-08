import Foundation

public struct BrowserSize: Equatable, Sendable {
    public var w: Double
    public var h: Double

    public init(w: Double, h: Double) {
        self.w = w
        self.h = h
    }

    public static let zero = BrowserSize(w: 0, h: 0)
}

public struct BrowserPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// The view's zoom and pan on top of the fitted page.
public struct BrowserViewTransform: Equatable, Sendable {
    /// Zoom relative to the fit size; 1 shows the whole page.
    public var zoom: Double
    /// Pan in view points, applied after the zoom.
    public var x: Double
    public var y: Double

    public init(zoom: Double, x: Double, y: Double) {
        self.zoom = zoom
        self.x = x
        self.y = y
    }

    public static let identity = BrowserViewTransform(zoom: 1, x: 0, y: 0)
}

/// Where the page sits inside the viewing area. The frame is drawn at its fit size (the whole
/// page visible, centred); the user's zoom and pan are a transform on top of that. Swift port of
/// `pai-cloud/web/src/apps/browser/viewGeometry.ts` — plain arithmetic so the screen-to-page
/// mapping that decides where a tap lands is checked without a device.
public enum BrowserGeometry {
    public static let minZoom = 1.0
    public static let maxZoom = 6.0

    /// Points per page pixel when the whole page fits the box.
    public static func fitScale(frame: BrowserSize, box: BrowserSize) -> Double {
        guard frame.w > 0, frame.h > 0, box.w > 0, box.h > 0 else { return 1 }
        return min(box.w / frame.w, box.h / frame.h)
    }

    /// Top-left of the fitted page inside the box (it is centred).
    public static func fitOrigin(frame: BrowserSize, box: BrowserSize) -> BrowserPoint {
        let scale = fitScale(frame: frame, box: box)
        return BrowserPoint(x: (box.w - frame.w * scale) / 2, y: (box.h - frame.h * scale) / 2)
    }

    /// Keep the zoomed page covering the box wherever it is larger than it; centred where smaller.
    public static func clamp(_ t: BrowserViewTransform, frame: BrowserSize, box: BrowserSize) -> BrowserViewTransform {
        let zoom = min(maxZoom, max(minZoom, t.zoom))
        let scale = fitScale(frame: frame, box: box) * zoom
        let origin = fitOrigin(frame: frame, box: box)

        func clampAxis(pan: Double, pageSize: Double, boxSize: Double, originPos: Double) -> Double {
            let shown = pageSize * scale
            if shown <= boxSize { return (boxSize - shown) / 2 - originPos * zoom }
            let lo = boxSize - shown - originPos * zoom
            let hi = -originPos * zoom
            return min(hi, max(lo, pan))
        }

        return BrowserViewTransform(
            zoom: zoom,
            x: clampAxis(pan: t.x, pageSize: frame.w, boxSize: box.w, originPos: origin.x),
            y: clampAxis(pan: t.y, pageSize: frame.h, boxSize: box.h, originPos: origin.y))
    }

    /// Zoom by `factor` keeping the box point (`px`, `py`) fixed on screen.
    public static func zoom(
        _ t: BrowserViewTransform, by factor: Double, aroundX px: Double, y py: Double, frame: BrowserSize,
        box: BrowserSize
    ) -> BrowserViewTransform {
        let zoom = min(maxZoom, max(minZoom, t.zoom * factor))
        let ratio = zoom / t.zoom
        return clamp(
            BrowserViewTransform(zoom: zoom, x: px - (px - t.x) * ratio, y: py - (py - t.y) * ratio),
            frame: frame, box: box)
    }

    /// The page point under a box point: screen = origin*zoom + page*fit*zoom + pan.
    public static func pagePoint(
        x px: Double, y py: Double, transform t: BrowserViewTransform, frame: BrowserSize, box: BrowserSize
    ) -> BrowserPoint {
        let scale = fitScale(frame: frame, box: box)
        let origin = fitOrigin(frame: frame, box: box)
        return BrowserPoint(
            x: (px - t.x - origin.x * t.zoom) / (scale * t.zoom),
            y: (py - t.y - origin.y * t.zoom) / (scale * t.zoom))
    }

    /// Whether a page point lies on the page (a tap on the letterbox is not a click).
    public static func isInsidePage(_ p: BrowserPoint, frame: BrowserSize) -> Bool {
        p.x >= 0 && p.y >= 0 && p.x <= frame.w && p.y <= frame.h
    }
}
