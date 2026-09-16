import Foundation

/// Strips anything that could be a live credential out of a string before it is allowed anywhere
/// it might be kept — a persisted log line, a test assertion, a printed diagnostic. Structural,
/// not value-based: it never sees the real key or token, only the shape it always takes on the
/// wire (a `token=`/`single_use_token=` query parameter, an `xi-api-key` header value, a `Bearer`
/// authorization header), so it works whether or not the actual secret is known to this process at
/// all.
public enum VoiceCredentialRedaction {
    private static let queryTokenPattern = try! NSRegularExpression(
        pattern: #"(?i)((?:single_use_)?token)=[^&\s"']+"#
    )
    private static let apiKeyHeaderPattern = try! NSRegularExpression(
        pattern: #"(?i)(xi-api-key)([\"'\s:=]+)[^\s"'&,}]+"#
    )
    private static let bearerTokenPattern = try! NSRegularExpression(
        pattern: #"(?i)(bearer)(\s+)[^\s"'&,}]+"#
    )

    public static func redact(_ text: String) -> String {
        var result = replacing(queryTokenPattern, in: text, template: "$1=<redacted>")
        result = replacing(apiKeyHeaderPattern, in: result, template: "$1$2<redacted>")
        result = replacing(bearerTokenPattern, in: result, template: "$1$2<redacted>")
        return result
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
