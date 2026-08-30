import PAIKit
import SwiftUI
import UIKit
import UserNotifications

/// The Apple-only half of push registration: asks for permission, asks APNs for a token, and
/// hands whatever comes back to ``PushRegistrationStore``, which owns every decision about it.
///
/// A `UIApplicationDelegate` because there is no other way to receive a device token — SwiftUI
/// has no equivalent, and the callback is delivered to the app delegate or nowhere.
///
/// Deliberately thin. Nothing here decides whether to ask, whether a token is stale, or whether
/// the backend needs telling; all of that is in the store, where it is tested on Linux for
/// nothing. This file is the part that cannot be tested at all, so it holds as little as
/// possible.
@MainActor
final class PushRegistrar: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Claiming the notification-centre delegate has to happen before launch finishes, or a tap
    /// that *started* the app is delivered to nobody — the system hands it over once, at launch,
    /// and drops it if there is no delegate yet. That is the cold-launch case, which is also the
    /// most common one for a notification.
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// What to show for a notification that arrives while the app is frontmost.
    ///
    /// Without this method iOS shows nothing at all — the default is that an app in front of the
    /// user is assumed to be already telling them. That default is wrong here: this app is a view
    /// onto sessions running elsewhere, so a push about one of them is news whether or not
    /// another session happens to be on screen. Delivery was never the problem; the app was
    /// declining to draw it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// A tapped notification.
    ///
    /// Parked rather than acted on: this fires before there is a router — before there is a
    /// signed-in user, on a cold launch — so anything that navigated here would navigate against
    /// a sign-in screen and be lost. `RootView` takes it out of the inbox once it has somewhere
    /// to put it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = Self.stringPayload(response.notification.request.content.userInfo)
        guard let link = DeepLink.from(payload: payload) else { return }
        DeepLinkInbox.shared.receive(link)
    }

    /// Flattens the system's `[AnyHashable: Any]` to the string pairs `DeepLink` parses.
    ///
    /// The one step that genuinely cannot be tested — everything past it is a pure function with
    /// tests that run on Linux for nothing. Non-string values are dropped rather than described,
    /// since a link key is always a string and `String(describing:)` on the `aps` dictionary
    /// would only manufacture a value that looks like one.
    private static func stringPayload(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var payload: [String: String] = [:]
        for (key, value) in userInfo {
            guard let key = key as? String, let value = value as? String else { continue }
            payload[key] = value
        }
        return payload
    }

    /// Set once the app has a connection, since a token is worth nothing until there is a
    /// backend to send it to. Until then the callbacks below simply have nowhere to put their
    /// answer, which is the correct behaviour rather than a dropped result — APNs reissues the
    /// same token on the next `registerForRemoteNotifications()`.
    static weak var store: PushRegistrationStore?

    /// Re-asks APNs for this install's token when permission has already been granted, and does
    /// nothing at all otherwise — it never shows a prompt, so it is safe on every launch.
    ///
    /// Separate from `requestAuthorizationIfNeeded` because that one is a *choice put to the
    /// user* and belongs behind a deliberate tap, while this is bookkeeping that has to happen
    /// whether or not anyone visits Settings. Also what sets `store`, so the delegate callbacks
    /// below have somewhere to deliver to on a launch where nobody opens that screen.
    static func registerForRemoteNotificationsIfAuthorized(store: PushRegistrationStore) async {
        Self.store = store
        guard store.registration.status == .authorized else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Asks for permission and, if granted, for a token.
    ///
    /// Safe to call more than once: the system prompt appears at most once per install, and the
    /// store refuses to ask again once it has an answer. Call it at a moment that makes sense to
    /// the person answering — the prompt is one-shot, so a cold first launch before they have
    /// seen the app work is the worst moment to spend it.
    static func requestAuthorizationIfNeeded(store: PushRegistrationStore) async {
        Self.store = store
        guard store.shouldRequestAuthorization else {
            // Already answered. A token may still be owed to the backend from a previous launch
            // that had no network, so ask for one rather than returning early.
            if store.registration.status == .authorized {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return
        }
        let granted =
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [
                .alert, .sound, .badge,
            ])) ?? false
        store.recordAuthorization(granted: granted)
        guard granted else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        Self.store?.recordDeviceToken(PushRegistration.hexToken(from: deviceToken))
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        Self.store?.recordRegistrationFailure(error.localizedDescription)
    }
}
