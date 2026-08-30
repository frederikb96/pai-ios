import Foundation

/// What staging should do to an image before it is uploaded — the decision half of attachment
/// compression, separated from the pixel work so it can be reasoned about and tested without an
/// image library.
public struct AttachmentStagingPlan: Equatable, Sendable {
    /// What to multiply both axes by before re-encoding. `1` re-encodes at the original size,
    /// which is what a transcode out of an unreadable format needs.
    public let scale: Double
    /// Whether a re-encode that came out no smaller than the original should be abandoned in
    /// favour of shipping the original bytes.
    public let abandonIfNotSmaller: Bool

    public init(scale: Double, abandonIfNotSmaller: Bool) {
        self.scale = scale
        self.abandonIfNotSmaller = abandonIfNotSmaller
    }
}

public enum AttachmentStaging {
    /// The web's `compressImage` bound (`utils/image.ts`), which this mirrors.
    public static let maxDimension: Double = 1920
    public static let jpegQuality: Double = 0.85

    /// Image formats every consumer downstream can open.
    ///
    /// The list matters because an iPhone hands over HEIC for anything that came out of its own
    /// camera, and the pasteboard offers exactly what was copied. HEIC is unreadable outside
    /// Apple's stack, so it arrives as a file nothing on the other end can open. The web composer
    /// never has to think about this: a browser hands JavaScript a PNG or a JPEG whatever the
    /// clipboard actually held, so its "leave a small image alone" rule can only ever leave alone
    /// something readable.
    public static let portableTypes: Set<String> = [
        "image/jpeg", "image/jpg", "image/png", "image/gif", "image/webp",
    ]

    /// `nil` means ship the bytes exactly as they arrived.
    ///
    /// - Parameter longestEdge: the image's longer axis in pixels.
    public static func plan(mimeType: String, longestEdge: Double) -> AttachmentStagingPlan? {
        let type = mimeType.lowercased()
        // SVG is an image that has no pixels to resample and no size problem to solve; rasterising
        // it would throw away the one property that makes it worth sending.
        guard type.hasPrefix("image/"), type != "image/svg+xml" else { return nil }

        let isPortable = portableTypes.contains(type)
        let oversized = longestEdge > maxDimension
        guard oversized || !isPortable else { return nil }

        // 🚨 The size guard applies to a resize and never to a transcode. HEIC is the more
        // efficient codec, so a faithful JPEG of one is routinely *larger* — and abandoning the
        // re-encode on that basis would ship the unreadable original every time, which is the
        // whole failure this exists to prevent.
        return AttachmentStagingPlan(
            scale: oversized ? maxDimension / longestEdge : 1,
            abandonIfNotSmaller: isPortable)
    }
}
