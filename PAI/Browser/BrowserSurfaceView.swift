import PAIKit
import SwiftUI
import UIKit

/// Draws the newest frame of an agent browser session and turns touches on it into page input.
///
/// The picture sits in a `content` view that is laid out at the page's fit size and moved by the
/// gesture interpreter's zoom and pan (`translate(x, y) scale(zoom)` about the box's top-left,
/// like the web client's CSS transform), so a pinch never redraws anything. Touches are read
/// raw rather than through gesture recognizers: the interpreter owns the one-finger/two-finger
/// rules, and recognizers competing over the same touches would be a second set of them.
final class BrowserSurfaceView: UIView {
    private let gestures: BrowserGestureInterpreter
    private let content = UIView()
    private let imageView = UIImageView()
    private var longPressTask: Task<Void, Never>?
    private var decodeSerial = 0
    private var touchIDs: [ObjectIdentifier: Int] = [:]
    private var nextTouchID = 0

    init(gestures: BrowserGestureInterpreter) {
        self.gestures = gestures
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.07, alpha: 1)
        clipsToBounds = true
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "browser-surface"

        // Transformed about the box's top-left, as the web's `transform-origin: 0 0`.
        content.layer.anchorPoint = .zero
        content.isUserInteractionEnabled = false
        imageView.contentMode = .scaleToFill
        addSubview(content)
        content.addSubview(imageView)

        gestures.onTransformChange = { [weak self] in self?.applyTransform() }
        gestures.armLongPress = { [weak self] in self?.armLongPress() }
        gestures.cancelLongPress = { [weak self] in
            self?.longPressTask?.cancel()
            self?.longPressTask = nil
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        content.bounds = CGRect(origin: .zero, size: bounds.size)
        content.layer.position = .zero
        gestures.setBoxSize(BrowserSize(w: bounds.width, h: bounds.height))
        layoutPicture()
        applyTransform()
    }

    // MARK: Picture

    func display(_ frame: BrowserFrame) {
        decodeSerial += 1
        let serial = decodeSerial
        let jpeg = frame.jpeg
        layoutPicture()
        Task {
            // Decoded off the main thread, and a slower decode never overwrites a newer frame.
            let image = await Task.detached { UIImage(data: jpeg)?.preparingForDisplay() }.value
            guard serial == decodeSerial, let image else { return }
            imageView.image = image
        }
    }

    private func layoutPicture() {
        let frame = gestures.frameSize
        let box = gestures.boxSize
        let scale = BrowserGeometry.fitScale(frame: frame, box: box)
        let origin = BrowserGeometry.fitOrigin(frame: frame, box: box)
        imageView.frame = CGRect(x: origin.x, y: origin.y, width: frame.w * scale, height: frame.h * scale)
    }

    private func applyTransform() {
        let t = gestures.transform
        content.transform = CGAffineTransform(a: t.zoom, b: 0, c: 0, d: t.zoom, tx: t.x, ty: t.y)
    }

    private func armLongPress() {
        longPressTask?.cancel()
        longPressTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(BrowserGestureInterpreter.longPressDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.gestures.longPressFired()
        }
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            nextTouchID += 1
            touchIDs[ObjectIdentifier(touch)] = nextTouchID
            let point = touch.location(in: self)
            gestures.touchDown(id: nextTouchID, x: point.x, y: point.y)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            gestures.touchMoved(id: id, x: point.x, y: point.y)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            let point = touch.location(in: self)
            gestures.touchUp(id: id, x: point.x, y: point.y)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let id = touchIDs.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            gestures.touchCancelled(id: id)
        }
    }
}

struct BrowserSurface: UIViewRepresentable {
    let store: BrowserViewStore

    func makeUIView(context: Context) -> BrowserSurfaceView {
        let view = BrowserSurfaceView(gestures: store.gestures)
        store.onFrame = { [weak view] frame in view?.display(frame) }
        if let frame = store.newestFrame { view.display(frame) }
        return view
    }

    func updateUIView(_ uiView: BrowserSurfaceView, context: Context) {}
}
