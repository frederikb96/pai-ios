import Foundation

/// Computes a block's height for a given width and font environment.
///
/// The real implementation needs TextKit or CoreText for everything except ``MarkdownBlock/table``
/// — GFM tables have no usable TextKit representation on iOS, so that case is expected to be
/// measured as its own layout (a fixed row height times row count, or a real trial layout of the
/// table subview) rather than through an attributed string. Neither concern belongs in this
/// package: importing either framework here would drop every test in it onto a metered runner,
/// which is exactly the cost this abstraction exists to avoid. Everything that composes and
/// caches block heights (``BlockHeightCache``, ``MessageContentLayoutComposer``) is proven here
/// against a deterministic stub instead; only the conformance that does real text layout is
/// unverified until it runs on Apple hardware.
///
/// A conforming type must be a **pure function** of its three inputs: the same block, width and
/// environment must always produce the same height. ``BlockHeightCache`` relies on this — it may
/// call a conforming type more than once for the same key under concurrent access, and treats
/// that as wasted work rather than a race to guard against, exactly because a pure measurer makes
/// the two calls' results interchangeable.
public protocol BlockMeasuring: Sendable {
    /// Returns the exact height `block` occupies at `width`, under `environment`.
    ///
    /// Must be synchronous, and must not guess. Every row in the transcript is placed with a
    /// height that was actually measured — never an estimate the layout will correct once the row
    /// is on screen, which is the failure mode `scrolling/references/native.md` documents as the
    /// thing precomputed heights exist to rule out.
    func height(of block: MarkdownBlock, width: Double, environment: MeasurementEnvironment) -> Double
}
