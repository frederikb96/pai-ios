import Foundation

/// Parsing the ISO 8601 timestamps this backend actually sends.
///
/// 🚨 **A bare `ISO8601DateFormatter()` cannot read them**, and that is not a corner case: its
/// default options reject a fractional-seconds component outright, and every timestamp the pod
/// serialises from Python carries one — `2026-08-30T22:30:00.506812+00:00`. The failure is a
/// `nil`, which every call site reasonably reads as "the server did not send this", so a field
/// that is present on the wire simply never appears on screen and nothing anywhere reports an
/// error. That is exactly how the plan-usage reset time went missing.
///
/// Two shapes have to be accepted, because both occur: with a fraction and without. And a
/// fraction of *six* digits has to survive, which is where relying on `.withFractionalSeconds`
/// alone is a gamble — it is specified around milliseconds, so the digits are trimmed to three
/// here rather than left to each platform's formatter to interpret. That keeps the answer the
/// same on the Linux toolchain the tests run on and on the phone, which is the only reason the
/// tests below mean anything.
public enum IsoTimestamp {

    public static func date(from text: String) -> Date? {
        let normalised = trimmingFractionToMilliseconds(text)
        lock.lock()
        defer { lock.unlock() }
        return fractional.date(from: normalised) ?? plain.date(from: normalised)
    }

    /// Shortens a fractional-seconds run to at most three digits, leaving everything around it —
    /// the offset or `Z` that follows it very much included — untouched.
    static func trimmingFractionToMilliseconds(_ text: String) -> String {
        guard let dot = text.firstIndex(of: ".") else { return text }
        var end = text.index(after: dot)
        while end < text.endIndex, text[end].isNumber {
            end = text.index(after: end)
        }
        let digits = text.distance(from: text.index(after: dot), to: end)
        guard digits > 3 else { return text }
        let keep = text.index(dot, offsetBy: 4)
        return String(text[text.startIndex..<keep]) + String(text[end...])
    }

    /// `ISO8601DateFormatter` is a reference type with no documented thread-safety guarantee on
    /// every platform this runs on, and this is called from view bodies on the main actor as well
    /// as from tests off it. One lock around two shared instances is cheaper than allocating a
    /// formatter per row per layout pass, which is the rate the session list would ask for.
    private static let lock = NSLock()

    private nonisolated(unsafe) static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private nonisolated(unsafe) static let plain = ISO8601DateFormatter()
}
