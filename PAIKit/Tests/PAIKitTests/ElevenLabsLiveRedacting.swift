import Foundation

/// Strips anything that could be a live ElevenLabs credential out of text before it can reach an
/// assertion message or a printed log line — a single-use token riding a `token=`/
/// `single_use_token=` query parameter, or an `xi-api-key` header value formatted into a string.
/// Every live test in this file routes a URL, a header dump or an error description through this
/// before it is allowed anywhere XCTest might echo it back (a failure message, `print`, a log
/// file). Structural, not value-based: it never sees the real key or a real token, only the shape
/// they always take on the wire, so it works whether or not the actual secret is known to this
/// process at all.
enum ElevenLabsLiveRedacting {
    private static let queryTokenPattern = try! NSRegularExpression(
        pattern: #"(?i)((?:single_use_)?token)=[^&\s"']+"#
    )
    private static let apiKeyHeaderPattern = try! NSRegularExpression(
        pattern: #"(?i)(xi-api-key)([\"'\s:=]+)[^\s"'&,}]+"#
    )

    static func redact(_ text: String) -> String {
        var result = replacing(queryTokenPattern, in: text, template: "$1=<redacted>")
        result = replacing(apiKeyHeaderPattern, in: result, template: "$1$2<redacted>")
        return result
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
