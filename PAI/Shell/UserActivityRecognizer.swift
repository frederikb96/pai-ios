import UIKit

/// Reports real input — a touch or a hardware key — anywhere in a window, without taking part in
/// it: it fails at once, so every other recognizer and the responder chain see the event as if
/// it were not there. The app coming to the front produces none of these, which is the point;
/// `SessionAttention` reads it as the one sign that someone is at the phone.
final class UserActivityRecognizer: UIGestureRecognizer {
    /// Set once by `RootView`; the single listener for the whole app.
    @MainActor static var onActivity: (() -> Void)?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { report() }
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) { report() }

    private func report() {
        Self.onActivity?()
        state = .failed
    }

    /// Adds the recognizer to every window that does not carry one; safe to call repeatedly.
    @MainActor static func installOnAllWindows() {
        for case let windowScene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in windowScene.windows
            where !(window.gestureRecognizers ?? []).contains(where: { $0 is UserActivityRecognizer }) {
                window.addGestureRecognizer(UserActivityRecognizer())
            }
        }
    }
}
