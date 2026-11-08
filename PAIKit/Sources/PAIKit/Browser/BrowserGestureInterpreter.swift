import Foundation

/// What touches on the live page mean: a tap clicks, a one-finger drag scrolls the page, two
/// fingers pinch and pan the view, a long press right-clicks. Swift port of the touch half of
/// `LiveView.tsx`, with the same thresholds, so the two clients answer a gesture alike.
///
/// The view feeds it raw touches and arms one timer for the long press; everything it decides
/// comes back through `send` (page input) and `onTransformChange` (the view's own zoom and pan).
/// Coordinates are view points inside the box the page is drawn in.
@MainActor
public final class BrowserGestureInterpreter {
    /// A touch that moves less than this (in points) and ends is a tap, not a scroll.
    public static let tapSlop = 8.0
    /// A touch held this long without moving is a right click.
    public static let longPressDelay: TimeInterval = 0.6
    public static let buttonZoomStep = 1.5

    public var send: (BrowserInput) -> Void = { _ in }
    public var onTransformChange: () -> Void = {}
    /// Start the long-press timer; its expiry calls ``longPressFired()``.
    public var armLongPress: () -> Void = {}
    public var cancelLongPress: () -> Void = {}

    public private(set) var frameSize = BrowserSize.zero
    public private(set) var boxSize = BrowserSize.zero
    /// Always inside what ``BrowserGeometry/clamp(_:frame:box:)`` allows for the current sizes.
    public private(set) var transform = BrowserViewTransform.identity

    private struct Pointer {
        let id: Int
        var x: Double
        var y: Double
        let startX: Double
        let startY: Double
        var moved = false
        /// Took part in a pinch, or arrived beside one: neither clicks nor scrolls.
        var ignored = false
    }

    private struct PinchStart {
        let distance: Double
        let transform: BrowserViewTransform
        let midX: Double
        let midY: Double
    }

    private var pointers: [Pointer] = []
    private var pinch: PinchStart?

    public init() {}

    // MARK: Geometry

    public func setFrameSize(_ size: BrowserSize) {
        guard size != frameSize else { return }
        frameSize = size
        reclamp()
    }

    public func setBoxSize(_ size: BrowserSize) {
        guard size != boxSize else { return }
        boxSize = size
        reclamp()
    }

    /// Points per page pixel at the current zoom.
    public var pointsPerPagePixel: Double {
        BrowserGeometry.fitScale(frame: frameSize, box: boxSize) * transform.zoom
    }

    private func reclamp() {
        transform = BrowserGeometry.clamp(transform, frame: frameSize, box: boxSize)
        onTransformChange()
    }

    private func pagePoint(_ x: Double, _ y: Double) -> BrowserPoint {
        BrowserGeometry.pagePoint(x: x, y: y, transform: transform, frame: frameSize, box: boxSize)
    }

    // MARK: Buttons

    public func zoomIn() { zoomFromCentre(by: Self.buttonZoomStep) }

    public func zoomOut() { zoomFromCentre(by: 1 / Self.buttonZoomStep) }

    public func fitPage() {
        transform = BrowserGeometry.clamp(.identity, frame: frameSize, box: boxSize)
        onTransformChange()
    }

    private func zoomFromCentre(by factor: Double) {
        transform = BrowserGeometry.zoom(
            transform, by: factor, aroundX: boxSize.w / 2, y: boxSize.h / 2, frame: frameSize, box: boxSize)
        onTransformChange()
    }

    // MARK: Touches

    public func touchDown(id: Int, x: Double, y: Double) {
        var pointer = Pointer(id: id, x: x, y: y, startX: x, startY: y)
        pointer.ignored = !pointers.isEmpty
        pointers.append(pointer)

        if pointers.count == 2 {
            cancelLongPress()
            for index in pointers.indices { pointers[index].ignored = true }
            let (a, b) = (pointers[0], pointers[1])
            pinch = PinchStart(
                distance: hypot(a.x - b.x, a.y - b.y) == 0 ? 1 : hypot(a.x - b.x, a.y - b.y),
                transform: transform, midX: (a.x + b.x) / 2, midY: (a.y + b.y) / 2)
            return
        }
        if pointers.count == 1 { armLongPress() }
    }

    public func touchMoved(id: Int, x: Double, y: Double) {
        guard let index = pointers.firstIndex(where: { $0.id == id }) else { return }
        let dx = x - pointers[index].x
        let dy = y - pointers[index].y
        pointers[index].x = x
        pointers[index].y = y

        if let start = pinch, pointers.count >= 2 {
            let (a, b) = (pointers[0], pointers[1])
            let distance = hypot(a.x - b.x, a.y - b.y)
            let midX = (a.x + b.x) / 2
            let midY = (a.y + b.y) / 2
            var next = BrowserGeometry.zoom(
                start.transform, by: (distance == 0 ? 1 : distance) / start.distance,
                aroundX: start.midX, y: start.midY, frame: frameSize, box: boxSize)
            next.x += midX - start.midX
            next.y += midY - start.midY
            transform = BrowserGeometry.clamp(next, frame: frameSize, box: boxSize)
            onTransformChange()
            return
        }

        let pointer = pointers[index]
        if pointer.ignored { return }
        if !pointer.moved && hypot(x - pointer.startX, y - pointer.startY) < Self.tapSlop { return }
        pointers[index].moved = true
        cancelLongPress()
        let origin = pagePoint(pointer.startX, pointer.startY)
        let scale = pointsPerPagePixel
        send(.wheel(x: origin.x, y: origin.y, dx: -dx / scale, dy: -dy / scale))
    }

    public func touchUp(id: Int, x: Double, y: Double) {
        guard let index = pointers.firstIndex(where: { $0.id == id }) else { return }
        let pointer = pointers.remove(at: index)
        cancelLongPress()
        if pointers.count < 2 { pinch = nil }
        if pointer.moved || pointer.ignored { return }
        let point = pagePoint(pointer.startX, pointer.startY)
        if BrowserGeometry.isInsidePage(point, frame: frameSize) {
            send(.mouse(action: .click, x: point.x, y: point.y, button: .left))
        }
    }

    /// The system took the touch away (a call, a system gesture): never a click.
    public func touchCancelled(id: Int) {
        guard let index = pointers.firstIndex(where: { $0.id == id }) else { return }
        pointers.remove(at: index)
        cancelLongPress()
        if pointers.count < 2 { pinch = nil }
    }

    /// The long-press timer expired with the finger still down.
    public func longPressFired() {
        guard pointers.count == 1, !pointers[0].moved, !pointers[0].ignored else { return }
        let point = pagePoint(pointers[0].x, pointers[0].y)
        pointers[0].moved = true
        if BrowserGeometry.isInsidePage(point, frame: frameSize) {
            send(.mouse(action: .click, x: point.x, y: point.y, button: .right))
        }
    }
}
