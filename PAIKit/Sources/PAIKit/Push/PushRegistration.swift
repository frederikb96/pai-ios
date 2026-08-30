import Foundation

/// What the app knows about its own ability to receive a push notification.
///
/// Deliberately a plain value type with no UIKit and no `UNUserNotificationCenter`: the parts of
/// registration that can be got wrong are the token encoding and the decision of when to talk to
/// the backend, and both of those are pure. Everything Apple-only is a thin caller around this,
/// which is what keeps this half provable on the free Linux runner.
public struct PushRegistration: Codable, Sendable, Equatable {

    /// Where registration has got to. The order is the order it happens in, and every step can
    /// fail independently — the common real-world shape is `.authorized` with a token that the
    /// backend has never seen, because the device had no network the moment it was minted.
    public enum Status: String, Codable, Sendable, CaseIterable {
        /// Nothing has been asked for yet. The system prompt is one-shot per install, so this is
        /// a state worth staying in until asking makes sense to the person answering.
        case notRequested
        /// The prompt was shown and refused. Nothing can re-prompt; only the Settings app can
        /// change it, so this state exists to be explained rather than retried.
        case denied
        /// Permission granted and APNs has issued a token for this install.
        case authorized
        /// Permission granted but APNs refused to issue a token.
        case failed
    }

    public var status: Status
    /// The APNs device token, lowercase hex. Absent until APNs issues one.
    public var deviceToken: String?
    /// The token the backend has confirmed storing. Kept separately from `deviceToken` so a
    /// registration that failed to reach the backend is distinguishable from one that never
    /// happened — the two look identical if only the token is stored.
    public var registeredToken: String?
    /// Why the last attempt failed, for the diagnostics screen. Never shown as an alert: a
    /// person who has just granted permission does not want an error about plumbing.
    public var lastError: String?

    public init(
        status: Status = .notRequested,
        deviceToken: String? = nil,
        registeredToken: String? = nil,
        lastError: String? = nil
    ) {
        self.status = status
        self.deviceToken = deviceToken
        self.registeredToken = registeredToken
        self.lastError = lastError
    }

    /// Whether the backend needs to be told about this token.
    ///
    /// True when a token exists and differs from the one the backend has confirmed — which
    /// covers the first registration, a token Apple has rotated, and a previous attempt that
    /// never reached the server. False once they agree, so an app that launches every day does
    /// not POST every day.
    public var needsBackendRegistration: Bool {
        guard let deviceToken, !deviceToken.isEmpty else { return false }
        return deviceToken != registeredToken
    }

    /// Whether asking the system for permission can still achieve anything. Once the prompt has
    /// been answered it never appears again, so re-requesting on a denied install is a no-op
    /// that reads in the code like a retry.
    public var canRequestAuthorization: Bool {
        status == .notRequested
    }

    /// Apple hands the token over as opaque bytes; APNs and every backend library want it as
    /// lowercase hex.
    ///
    /// Written out rather than reached for via a formatting API because the failure mode is
    /// silent: a token encoded any other way is still a plausible-looking string, the register
    /// call still succeeds, and the only symptom is that notifications never arrive.
    public static func hexToken(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
