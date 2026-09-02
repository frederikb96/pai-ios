/// Which of the system's currently-delivered notification banners are safe to remove because the
/// account has since marked them read — anywhere, not just on this device (row 24.7).
///
/// A pure function over already-fetched state (`NotificationCenterStore.readStatus(forIDs:)`),
/// kept separate from that fetch so the decision itself — which ids to actually hand to
/// `UNUserNotificationCenter.removeDeliveredNotifications(withIdentifiers:)` — is testable on
/// Linux without `UserNotifications`, which exists nowhere but Apple platforms.
public enum NotificationDeliveryReconciliation {
    /// `deliveredIDs` are `pai_notification_id` values read out of each delivered notification's
    /// own payload (`DeepLink.notificationIDKey`); `readStatus` is whatever
    /// `NotificationCenterStore.readStatus(forIDs:)` could confirm for them. An id `readStatus`
    /// has no opinion on — a failed lookup, or one this call was never asked about — is left out
    /// rather than assumed clear: removing a still-unread notification's banner would make the
    /// springboard badge and the shade disagree with each other, exactly the inconsistency this
    /// feature exists to prevent.
    public static func idsToClear(deliveredIDs: [String], readStatus: [String: Bool]) -> [String] {
        deliveredIDs.filter { readStatus[$0] == true }
    }
}
