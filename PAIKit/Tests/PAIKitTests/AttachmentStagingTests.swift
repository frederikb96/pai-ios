import Testing

@testable import PAIKit

@Suite("Attachment staging")
struct AttachmentStagingTests {

    @Test("An image already within the bound, in a format everything reads, is left alone")
    func portableAndSmallIsUntouched() {
        #expect(AttachmentStaging.plan(mimeType: "image/jpeg", longestEdge: 1200) == nil)
        #expect(AttachmentStaging.plan(mimeType: "image/png", longestEdge: 1920) == nil)
    }

    @Test("An oversized image is scaled to the bound")
    func oversizedIsScaled() {
        let plan = AttachmentStaging.plan(mimeType: "image/jpeg", longestEdge: 3840)
        #expect(plan?.scale == 0.5)
    }

    /// The failure this guards: an iPhone puts HEIC on the pasteboard, HEIC is unreadable outside
    /// Apple's stack, and a small one sails past a rule that only asks about size.
    @Test("An unreadable format is re-encoded whatever its size")
    func unreadableFormatIsAlwaysReencoded() {
        let plan = AttachmentStaging.plan(mimeType: "image/heic", longestEdge: 800)
        #expect(plan != nil)
        #expect(plan?.scale == 1)
    }

    /// HEIC is the more efficient codec, so a faithful JPEG of one is routinely larger. Applying
    /// the resize path's "keep the original if it did not shrink" rule to a transcode would ship
    /// the unreadable bytes every single time — a fix that passes every other check.
    @Test("A transcode is never abandoned for coming out larger")
    func transcodeIgnoresTheSizeGuard() {
        #expect(AttachmentStaging.plan(mimeType: "image/heic", longestEdge: 800)?.abandonIfNotSmaller == false)
        #expect(AttachmentStaging.plan(mimeType: "image/heif", longestEdge: 4000)?.abandonIfNotSmaller == false)
        #expect(AttachmentStaging.plan(mimeType: "image/jpeg", longestEdge: 4000)?.abandonIfNotSmaller == true)
    }

    @Test("Type matching ignores case, as a header may send it either way")
    func typeMatchingIsCaseInsensitive() {
        #expect(AttachmentStaging.plan(mimeType: "IMAGE/PNG", longestEdge: 100) == nil)
    }

    @Test("Anything that is not a raster image is shipped as it arrived")
    func nonRasterIsShippedUntouched() {
        #expect(AttachmentStaging.plan(mimeType: "application/pdf", longestEdge: 4000) == nil)
        #expect(AttachmentStaging.plan(mimeType: "text/plain", longestEdge: 0) == nil)
        // Rasterising a vector throws away the one property that makes it worth sending.
        #expect(AttachmentStaging.plan(mimeType: "image/svg+xml", longestEdge: 9000) == nil)
    }
}
