/// Light, dark, or whatever the phone is set to.
///
/// The web offers the same three, and `system` is the default there too. The mapping onto
/// SwiftUI's `preferredColorScheme` is the view's business — `system` is `nil`, which is why this
/// is an enum rather than an optional: a `nil` meaning "no preference stored" and a `nil` meaning
/// "follow the system" are different facts that would otherwise share a representation.
public enum AppTheme: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark
}
