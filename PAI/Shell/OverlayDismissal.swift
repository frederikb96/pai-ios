import UIKit

/// Closes whatever the app is presenting — a sheet, a full-screen cover, anything stacked on
/// either — so a navigation that follows lands on a screen nothing covers.
///
/// Works on UIKit's presentation chain rather than on each SwiftUI `isPresented` binding, because
/// the overlays are presented from many places (the new-session sheet, Apps, recordings, the ARC
/// sheets) and a path change underneath them does not reliably take them down. Dismissing the
/// bottom of the chain takes everything above it too, and each SwiftUI sheet runs its own
/// `onDisappear` on the way out.
///
/// `completion` runs once the dismissal has finished, or at once when nothing is presented: a
/// path change made while a sheet is still dismissing is dropped silently.
@MainActor
enum OverlayDismissal {
    static func dismissAll(completion: @escaping @MainActor () -> Void) {
        guard let root = rootViewController(), root.presentedViewController != nil else {
            completion()
            return
        }
        root.dismiss(animated: true) { Task { @MainActor in completion() } }
    }

    private static func rootViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        let windows = scene?.windows ?? []
        return (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
    }
}
