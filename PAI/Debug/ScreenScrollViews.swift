#if DEBUG
    import UIKit

    /// Every `UIScrollView` on the app's window as the debug bridge reports it, without the
    /// keyboard and without the field editor a focused search field scrolls its text in.
    struct ScreenScrollViews: Encodable {
        struct View: Encodable {
            let type: String
            let x, y, width, height: Double
        }

        let views: [View]

        @MainActor static func current() -> ScreenScrollViews {
            let windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .filter { $0.windowLevel == .normal }
            var found: [View] = []
            for window in windows { collect(window, in: window, into: &found) }
            return ScreenScrollViews(views: found)
        }

        @MainActor private static func collect(_ view: UIView, in window: UIWindow, into found: inout [View]) {
            if view is UIScrollView, !view.isHidden, !(view is UITextInput) {
                let frame = view.convert(view.bounds, to: window)
                found.append(
                    View(
                        type: String(describing: type(of: view)), x: frame.minX, y: frame.minY,
                        width: frame.width, height: frame.height))
            }
            for child in view.subviews { collect(child, in: window, into: &found) }
        }
    }
#endif
