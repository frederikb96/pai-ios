import Foundation

/// The part of a block's height that comes from outside the block itself.
///
/// A ``MarkdownBlock`` is the same value everywhere it appears, but the same block is a different
/// height at a different width, and a different height again after Dynamic Type changes. Both
/// belong in the measurement cache's key alongside the block, which is what this type exists to
/// carry.
///
/// `sizeCategoryToken` is deliberately opaque: this package does not know what
/// `UIContentSizeCategory` values exist or how they order, only that two different tokens mean
/// two different measurements. Passing `UIContentSizeCategory.rawValue` straight through from the
/// app target costs nothing and keeps that enumeration's specifics out of a package that has to
/// keep building where it does not exist.
public struct MeasurementEnvironment: Hashable, Sendable {
    public let sizeCategoryToken: String

    public init(sizeCategoryToken: String) {
        self.sizeCategoryToken = sizeCategoryToken
    }
}
