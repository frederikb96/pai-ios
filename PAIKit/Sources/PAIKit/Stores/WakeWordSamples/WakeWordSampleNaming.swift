import Foundation

/// Turns a run's kind, label and take position into a filesystem-safe WAV filename — pure string
/// work, so the fast start/say/tap rhythm `WakeWordSampleCaptureController` (`PAI/`) drives never
/// has to reason about what characters a label might contain.
public enum WakeWordSampleNaming {
    /// `<kind>-<sanitized label>-<index>-<timestampMs>.wav`, or `<kind>-<index>-<timestampMs>.wav`
    /// when the label sanitizes to nothing. `index` is the take's 1-based position within its own
    /// run, so files from the same run sort — and read back — in recording order even when two
    /// runs share a label; `timestampMs` is what keeps two runs from ever colliding on the same
    /// name.
    public static func fileName(kind: WakeWordSample.Kind, label: String, index: Int, recordedAtMs: Double) -> String {
        let sanitizedLabel = sanitize(label)
        let stamp = Int(recordedAtMs)
        let stem =
            sanitizedLabel.isEmpty
            ? "\(kind.rawValue)-\(index)-\(stamp)" : "\(kind.rawValue)-\(sanitizedLabel)-\(index)-\(stamp)"
        return "\(stem).wav"
    }

    /// The id `WakeWordSample.id` uses — the filename minus its extension, so identity and
    /// on-disk address are never two values that can drift apart.
    public static func stem(from fileName: String) -> String {
        (fileName as NSString).deletingPathExtension
    }

    /// Lowercases, replaces any run of characters outside ASCII letters/digits with a single
    /// dash, and trims leading/trailing dashes — "loud + windy!!" becomes "loud-windy", an empty
    /// or all-punctuation label becomes "". Deliberately ASCII-only rather than folding
    /// diacritics: this only ever has to be a legal filename, not a display string.
    static func sanitize(_ label: String) -> String {
        let normalized = label.lowercased().unicodeScalars.map { scalar -> Character in
            scalar.isASCII && (("a"..."z").contains(Character(scalar)) || ("0"..."9").contains(Character(scalar)))
                ? Character(scalar) : " "
        }
        return String(normalized)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }
}
