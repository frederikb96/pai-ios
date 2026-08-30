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
final class PushRegistrar: NSObject, UIApplicationDelegate {

    /// Set once the app has a connection, since a token is worth nothing until there is a
    /// backend to send it to. Until then the callbacks below simply have nowhere to put their
    /// answer, which is the correct behaviour rather than a dropped result — APNs reissues the
    /// same token on the next `registerForRemoteNotifications()`.
    static weak var store: PushRegistrationStore?

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
